/**
 * dsh-pet host plugin — a pure Harness status bridge (no browser
 * UI, no settings namespace) that tracks agent activity and serves a stable
 * snapshot over HTTP and a local Unix socket for the DSH Pet macOS desktop app.
 * Install
 * via `dsh plugin --profile web add github:sundusk/dsh-pet`.
 * @module @sundusk/dsh-pet
 */

import { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-host-webserver'
import type { WebRoute } from '@deepseek-ai/dsh-host-webserver'
import type { PromptContentPart } from '@deepseek-ai/dsh-api-session-controller'
import type {} from '@deepseek-ai/dsh-workspace'
import type { Session } from '@deepseek-ai/dsh-session'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { basename } from 'node:path'
import {
  CommandBridge,
  type ImageAttachmentLimits,
  type DshPetTask,
  type DshPetWorkspace,
} from './CommandBridge.js'
import { LocalStateBridge, type MoodBridgePayload } from './LocalStateBridge.js'
import {
  createHarnessInstanceDescriptor,
  HarnessInstanceManifest,
  instanceDiscoveryDirectory,
  refreshHarnessInstanceWebURL,
  type HarnessInstanceDescriptor,
} from './HarnessInstance.js'

export { CommandBridge } from './CommandBridge.js'
export { LocalStateBridge } from './LocalStateBridge.js'
export {
  createHarnessInstanceDescriptor,
  HarnessInstanceManifest,
  instanceDiscoveryDirectory,
  instanceManifestPath,
  refreshHarnessInstanceWebURL,
} from './HarnessInstance.js'
export type { HarnessInstanceDescriptor, HarnessInstanceKind } from './HarnessInstance.js'

/** Stable cordis plugin name (matches cordis.patch.yml insert id). */
export const name = 'dsh-pet'

/** Services required before the status surface can mount. */
export const inject = ['webServer', 'workspaceRegistry', 'sessionController', 'attachments']

/** The mood the desktop app renders (same vocabulary as the web water ball). */
export type DshPetMood =
  | 'idle'
  | 'waiting'
  | 'jumping'
  | 'done'
  | 'failed'
  | 'stopped'
  | 'waving'
  | 'authorizing'
  | 'questioning'

type DshPetResult = Extract<DshPetMood, 'done' | 'failed' | 'stopped'>

function stateForMood(mood: DshPetMood): DshPetTask['state'] {
  switch (mood) {
    case 'waiting': return 'thinking'
    case 'jumping': return 'toolCalling'
    case 'authorizing': return 'waitingApproval'
    case 'questioning': return 'waitingUserAnswer'
    case 'done': return 'completed'
    case 'failed': return 'failed'
    case 'stopped': return 'stopped'
    case 'idle': return 'idle'
    default: return 'disconnected'
  }
}

function isRunningMood(mood: DshPetMood): boolean {
  return ['waiting', 'jumping', 'authorizing', 'questioning'].includes(mood)
}

/** Write one JSON response. */
function json(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify(body))
}

/**
 * Register the DSH Pet status surface: fold the agent session stream into a
 * stable snapshot, serve it over GET /api/dsh-pet/status, and broadcast the
 * same snapshot through LocalStateBridge. The route is always live while the
 * plugin is loaded — there is no settings namespace to toggle.
 * @param ctx - host root context.
 */
export function apply(ctx: Context): void {
  interface SessionMoodState {
    sessionId?: string
    workspaceId?: string
    mood: DshPetMood
    holdUntil: number
    questionActive: boolean
    /** Last terminal result stays on the task card until its next turn. */
    lastResult?: DshPetResult
    tool?: string
    message?: string
  }

  const globalState: SessionMoodState = {
    mood: 'idle',
    holdUntil: 0,
    questionActive: false,
  }
  const sessionStates = new Map<string, SessionMoodState>()
  const sessionOperations = new Map<string, Promise<void>>()
  let taskSnapshot: DshPetTask[] = []
  let taskRefreshTimer: ReturnType<typeof setTimeout> | undefined
  let refreshTaskSnapshot: (() => Promise<readonly DshPetTask[]>) | undefined
  let activeSessionId: string | undefined
  let commandBridge: CommandBridge | undefined
  const instance: HarnessInstanceDescriptor = createHarnessInstanceDescriptor(ctx)
  const instanceManifest = new HarnessInstanceManifest(
    instance,
    process.env.DSH_PET_INSTANCE_DIRECTORY
      ?? process.env.MOODBALL_INSTANCE_DIRECTORY
      ?? instanceDiscoveryDirectory(),
  )
  let statusReady = false
  let commandReady = false
  let originRetryTimer: ReturnType<typeof setTimeout> | undefined
  let instanceManifestPublished = false
  const publishInstanceManifest = (): void => {
    if (!statusReady || !commandReady || instanceManifestPublished) return
    const hasOriginGetter = typeof (ctx as unknown as { webServer?: { getOrigin?: unknown } }).webServer?.getOrigin === 'function'
    if (instance.kind === 'web' && hasOriginGetter && !refreshHarnessInstanceWebURL(instance, ctx)) {
      originRetryTimer ??= setTimeout(() => {
        originRetryTimer = undefined
        publishInstanceManifest()
      }, 100)
      return
    }
    refreshHarnessInstanceWebURL(instance, ctx)
    try {
      instanceManifest.publish()
      instanceManifestPublished = true
    } catch (error) {
      console.warn(`[dsh-pet] instance discovery unavailable: ${String(error)}`)
    }
  }

  const stateFor = (sessionId: string, workspaceId?: string): SessionMoodState => {
    const existing = sessionStates.get(sessionId)
    if (existing) {
      if (workspaceId) existing.workspaceId = workspaceId
      return existing
    }
    const created: SessionMoodState = {
      sessionId,
      workspaceId,
      mood: 'idle',
      holdUntil: 0,
      questionActive: false,
    }
    sessionStates.set(sessionId, created)
    return created
  }

  const workspaceForSession = (sessionId: string): string | undefined => {
    const workspace = ctx.workspaceRegistry.list().find(candidate =>
      candidate.sessionIds.some(candidateSessionId => String(candidateSessionId) === sessionId),
    )
    return workspace ? String(workspace.id) : undefined
  }

  const snapshotOf = (state: SessionMoodState): MoodBridgePayload => ({
    instanceId: instance.instanceId,
    state: stateForMood(state.mood),
    mood: state.mood,
    ...(state.sessionId ? { sessionId: state.sessionId } : {}),
    ...(state.workspaceId ? { workspaceId: state.workspaceId } : {}),
    taskRunning: ['waiting', 'jumping', 'authorizing', 'questioning'].includes(state.mood),
    waitingForUser: state.mood === 'authorizing' || state.mood === 'questioning',
    failed: state.mood === 'failed',
    completed: state.mood === 'done',
    ...(state.tool ? { tool: state.tool } : {}),
    ...(state.message ? { message: state.message } : {}),
    updatedAt: Date.now(),
  })

  const snapshotForSession = (sessionId: string): MoodBridgePayload =>
    snapshotOf(stateFor(sessionId, workspaceForSession(sessionId)))

  const snapshot = (): MoodBridgePayload =>
    activeSessionId === undefined
      ? snapshotOf(globalState)
      : snapshotForSession(activeSessionId)

  const localBridge = new LocalStateBridge(snapshot, instance.statusSocketPath)

  const workspaceForSummary = (sessionId: string) => ctx.workspaceRegistry.list().find(workspace =>
    workspace.sessionIds.some(candidate => String(candidate) === sessionId),
  )

  const titleForSummary = (summary: { sessionId: string; cwd?: string }, workspace: { title: string }): string => {
    const serviceContext = ctx as unknown as {
      get?: (name: string, strict?: boolean) => unknown
    }
    const sessions = serviceContext.get?.('sessions', false) as { get(id: string): Session | undefined } | undefined
    const titleService = serviceContext.get?.('sessionTitle', false) as {
      get(session: Session): { title?: string } | undefined
    } | undefined
    const liveSession = sessions?.get(summary.sessionId)
    const title = liveSession === undefined ? undefined : titleService?.get(liveSession)?.title
    if (title !== undefined && title.trim() !== '') return title

    const directory = summary.cwd === undefined ? '' : basename(summary.cwd)
    const suffix = summary.sessionId.slice(-8)
    return directory !== '' && directory !== workspace.title
      ? `${directory} · 会话 ${suffix}`
      : `会话 ${suffix}`
  }

  const tasksFromSummaries = (summaries: readonly {
    sessionId: string
    updatedAt: number
    running: boolean
    blank: boolean
    parentSessionId?: string
    origin?: 'subagent'
    cwd?: string
  }[]): DshPetTask[] => summaries.flatMap(summary => {
    // The task center is for ordinary user sessions only. Child Agent rows
    // remain visible inside Harness and must not compete with their parent.
    if (summary.parentSessionId !== undefined || summary.origin === 'subagent') return []
    const workspace = workspaceForSummary(summary.sessionId)
    if (workspace === undefined) return []

    const state = stateFor(summary.sessionId, String(workspace.id))
    let mood = state.mood
    if (summary.running && !isRunningMood(mood)) mood = 'waiting'
    if (!summary.running && isRunningMood(mood)) mood = 'idle'
    if (!summary.running && state.lastResult !== undefined) mood = state.lastResult
    const projected = snapshotOf({ ...state, mood, workspaceId: String(workspace.id) })
    return [{
      sessionId: summary.sessionId,
      workspaceId: String(workspace.id),
      title: titleForSummary(summary, workspace),
      ...(summary.cwd === undefined ? {} : { cwd: summary.cwd }),
      updatedAt: summary.updatedAt,
      running: summary.running,
      blank: summary.blank,
      state: projected.state as DshPetTask['state'],
      mood: projected.mood,
      taskRunning: summary.running || projected.taskRunning,
      waitingForUser: projected.waitingForUser,
      failed: projected.failed,
      completed: projected.completed,
      ...(projected.tool === undefined ? {} : { tool: projected.tool }),
      ...(projected.message === undefined ? {} : { message: projected.message }),
    }]
  })

  const scheduleTaskRefresh = (): void => {
    if (taskRefreshTimer !== undefined) return
    taskRefreshTimer = setTimeout(() => {
      taskRefreshTimer = undefined
      void refreshTaskSnapshot?.().catch(error => {
        console.warn(`[dsh-pet] task list refresh failed: ${String(error)}`)
      })
    }, 150)
  }

  const publish = (state: SessionMoodState): void => {
    localBridge.publish()
    if (state.sessionId) commandBridge?.publish(state.sessionId, snapshotOf(state))
    scheduleTaskRefresh()
  }

  // A transient mood (done / failed / stopped) holds for `ms` before reverting
  // to idle, so the colored reaction is visible instead of being swallowed by
  // the immediately following `activity/status` idle phase.
  const setTransient = (state: SessionMoodState, next: DshPetMood, ms: number): void => {
    state.mood = next
    if (next === 'done' || next === 'failed' || next === 'stopped') state.lastResult = next
    state.holdUntil = Date.now() + ms
    publish(state)
    setTimeout(() => {
      if (state.mood === next) {
        state.mood = 'idle'
        publish(state)
      }
    }, ms)
  }

  // Track each session independently. The legacy HTTP/socket snapshot follows
  // the most recently active session, while command subscribers receive only
  // the session they explicitly selected.
  ctx.on('session/event', (_session: Session, event: { type: string; data?: unknown }) => {
    const info = _session as unknown as { id?: string; sessionId?: string; workspaceId?: string }
    const sessionId = info.id ?? info.sessionId
    const state = sessionId === undefined
      ? globalState
      : stateFor(sessionId, info.workspaceId ?? workspaceForSession(sessionId))
    if (sessionId) activeSessionId = sessionId

    if (event.type === 'turn/start' || event.type === 'step/start' || event.type === 'assistant/chunk') {
      state.lastResult = undefined
      state.mood = 'waiting'
      state.holdUntil = 0
      state.message = undefined
    } else if (event.type === 'tool/call') {
      state.lastResult = undefined
      const call = (event.data ?? {}) as { name?: string }
      state.tool = call.name
      if (call.name === 'ask_user_question') {
        state.questionActive = true
        state.mood = 'questioning'
        state.holdUntil = 0
      } else {
        state.mood = 'jumping'
        state.holdUntil = 0
      }
    } else if (event.type === 'tool/result') {
      const result = (event.data ?? {}) as { error?: { code?: string } }
      if (state.questionActive) {
        state.questionActive = false
        if (result.error !== undefined) setTransient(state, 'stopped', 1500)
        else {
          state.mood = 'waiting'
          state.holdUntil = 0
        }
      } else {
        state.mood = 'waiting'
        state.holdUntil = 0
      }
    } else if (event.type === 'approval/asked') {
      state.lastResult = undefined
      state.mood = 'authorizing'
      state.holdUntil = 0
    } else if (event.type === 'approval/decided') {
      const payload = (event.data ?? {}) as { result?: string }
      if (payload.result === 'allowed-once') {
        state.lastResult = undefined
        state.mood = 'waiting'
        state.holdUntil = 0
      } else if (payload.result === 'rejected' || payload.result === 'cancelled' || payload.result === 'unavailable') {
        setTransient(state, 'failed', 3000)
      }
    } else if (event.type === 'activity/status') {
      const payload = (event.data ?? {}) as { phase?: string }
      if (payload.phase === undefined) return
      switch (payload.phase) {
        case 'waiting':
        case 'thinking':
          state.lastResult = undefined
          state.mood = 'waiting'
          state.holdUntil = 0
          state.message = undefined
          break
        case 'tool':
          if (state.questionActive) return
          state.lastResult = undefined
          state.mood = 'jumping'
          state.holdUntil = 0
          break
        case 'done':
          setTransient(state, 'done', 2500)
          break
        case 'idle':
          if (Date.now() < state.holdUntil) return
          state.mood = 'idle'
          state.tool = undefined
          state.message = undefined
          break
        default:
          break
      }
    } else if (event.type === 'turn/end') {
      state.questionActive = false
      const payload = (event.data ?? {}) as { reason?: { kind?: string } }
      const kind = payload.reason?.kind
      if (kind === 'error') setTransient(state, 'failed', 3000)
      else if (kind === 'completed') setTransient(state, 'done', 2500)
      else if (kind !== undefined) setTransient(state, 'stopped', 3000)
    }
    publish(state)
  })

  ctx.on('session/created', () => { scheduleTaskRefresh() })
  ctx.on('session/disposed', session => {
    sessionStates.delete(String(session.id))
    scheduleTaskRefresh()
  })

  const serializeSession = <T>(sessionId: string, operation: () => Promise<T>): Promise<T> => {
    const previous = sessionOperations.get(sessionId) ?? Promise.resolve()
    const result = previous.then(operation)
    const settled = result.then(() => undefined, () => undefined)
    sessionOperations.set(sessionId, settled)
    void settled.then(() => {
      if (sessionOperations.get(sessionId) === settled) sessionOperations.delete(sessionId)
    })
    return result
  }

  commandBridge = new CommandBridge({
    imageAttachmentLimits: (ctx as unknown as {
      attachments: { imageLimits: ImageAttachmentLimits }
    }).attachments.imageLimits,
    listWorkspaces: async (): Promise<readonly DshPetWorkspace[]> => Promise.all(
      ctx.workspaceRegistry.list().map(async workspace => ({
        id: String(workspace.id),
        title: workspace.title,
        path: workspace.path,
        status: await workspace.status(),
        sessionIds: workspace.sessionIds.map(String),
      })),
    ),
    listTasks: async (): Promise<readonly DshPetTask[]> => {
      if (refreshTaskSnapshot !== undefined) return refreshTaskSnapshot()
      return taskSnapshot
    },
    createSession: request => serializeSession(request.sessionId, async () => {
      const workspace = ctx.workspaceRegistry.get(request.workspaceId as never)
      if (workspace === undefined) throw new Error(`workspace "${request.workspaceId}" not found`)
      const result = await ctx.sessionController.create({
        workspaceId: workspace.id,
        sessionId: request.sessionId as never,
      })
      stateFor(String(result.sessionId), String(workspace.id)).workspaceId = String(workspace.id)
      return { sessionId: String(result.sessionId) }
    }),
    prompt: request => serializeSession(request.sessionId, async () => {
      const workspace = ctx.workspaceRegistry.get(request.workspaceId as never)
      if (workspace === undefined) throw new Error(`workspace "${request.workspaceId}" not found`)
      if (!workspace.sessionIds.some(candidate => String(candidate) === request.sessionId)) {
        throw new Error(`session "${request.sessionId}" is not attached to workspace "${request.workspaceId}"`)
      }
      const content: PromptContentPart[] = [
        ...(request.text.trim() === '' ? [] : [{ type: 'text' as const, text: request.text }]),
        ...request.images.map(image => ({ type: 'image' as const, ...image })),
      ]
      await ctx.sessionController.prompt({
        requestId: request.requestId as never,
        sessionId: request.sessionId as never,
        mode: 'queue',
        content,
      }, AbortSignal.timeout(30_000))
      return { accepted: true, sessionId: request.sessionId }
    }),
    snapshotFor: snapshotForSession,
  }, instance.commandSocketPath, instance)

  refreshTaskSnapshot = async (): Promise<readonly DshPetTask[]> => {
    const listed = await ctx.sessionController.list({}, AbortSignal.timeout(15_000))
    taskSnapshot = tasksFromSummaries(listed.items)
    commandBridge?.publishTasks(taskSnapshot)
    return taskSnapshot
  }

  ctx.effect(() => {
    statusReady = false
    commandReady = false
    localBridge.start(() => {
      statusReady = true
      publishInstanceManifest()
    })
    commandBridge?.start(() => {
      commandReady = true
      publishInstanceManifest()
    })
    void refreshTaskSnapshot?.().catch(error => {
      console.warn(`[dsh-pet] initial task list unavailable: ${String(error)}`)
    })
    return () => {
      if (taskRefreshTimer !== undefined) clearTimeout(taskRefreshTimer)
      taskRefreshTimer = undefined
      commandBridge?.stop()
      localBridge.stop()
      if (originRetryTimer !== undefined) clearTimeout(originRetryTimer)
      originRetryTimer = undefined
      instanceManifest.remove()
      instanceManifestPublished = false
      statusReady = false
      commandReady = false
    }
  }, 'dsh-pet: local bridges')

  const statusRoute: WebRoute = {
    kind: 'exact',
    path: '/api/dsh-pet/status',
    handler: (req: IncomingMessage, res: ServerResponse): void => {
      if (req.method !== 'GET') {
        json(res, 405, { ok: false, error: 'method-not-allowed' })
        return
      }
      json(res, 200, { ok: true, enabled: true, ...snapshot() })
    },
  }

  // Keep the former endpoint during the package rename so an older desktop
  // app can finish its upgrade without losing the status bridge.
  const legacyStatusRoute: WebRoute = { ...statusRoute, path: '/api/moodball/status' }

  // Route is always live: unlike the web water ball there is no settings
  // namespace, so nothing can take it down while the plugin is loaded.
  ctx.effect(() => {
    const dispose = ctx.webServer.register(statusRoute)
    const disposeLegacy = ctx.webServer.register(legacyStatusRoute)
    return () => {
      disposeLegacy()
      dispose()
    }
  }, 'dsh-pet: status routes')
}
