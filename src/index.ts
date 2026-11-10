/**
 * dsh-mac-pet host plugin — a Harness status bridge (no rendered browser UI, no
 * settings namespace) that tracks agent activity, serves a stable snapshot over
 * HTTP and a local Unix socket, and queues Session-open requests for the tiny
 * browser half.
 * Install
 * via `dsh plugin --profile web add dsh-mac-pet`.
 * @module dsh-mac-pet
 */

import { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-host-webserver'
import type { WebRoute } from '@deepseek-ai/dsh-host-webserver'
import type { PromptContentPart } from '@deepseek-ai/dsh-api-session-controller'
import type {} from '@deepseek-ai/dsh-workspace'
import type { Session } from '@deepseek-ai/dsh-session'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { randomUUID } from 'node:crypto'
import { basename } from 'node:path'
import {
  CommandBridge,
  type ImageAttachmentLimits,
  type DshPetTask,
  type DshPetWorkspace,
} from './CommandBridge.js'
import { LocalStateBridge, type MoodBridgePayload } from './LocalStateBridge.js'
import { detectHostApp } from './InstallDetection.js'
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
  const unconfirmedSessions = new Set<string>()
  const sessionOperations = new Map<string, Promise<void>>()
  let taskSnapshot: DshPetTask[] = []
  let taskRefreshTimer: ReturnType<typeof setTimeout> | undefined
  let refreshTaskSnapshot: ((timeoutMs?: number) => Promise<readonly DshPetTask[]>) | undefined
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

  const snapshotForTask = (task: DshPetTask): MoodBridgePayload => ({
    ...snapshotForSession(task.sessionId),
    state: task.state,
    mood: task.mood as DshPetMood,
    taskRunning: task.taskRunning,
    waitingForUser: task.waitingForUser,
    failed: task.failed,
    completed: task.completed,
  })

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
    if (state.sessionId) {
      const snapshot = snapshotOf(state)
      commandBridge?.publish(state.sessionId, unconfirmedSessions.has(state.sessionId)
        ? { ...snapshot, taskRunning: true, message: '无法确认任务状态，暂不可发送' }
        : snapshot)
    }
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
      const payload = (event.data ?? {}) as { outcome?: string; result?: string }
      const outcome = payload.outcome ?? payload.result
      if (outcome === 'allowed-once') {
        state.lastResult = undefined
        state.mood = 'waiting'
        state.holdUntil = 0
      } else if (outcome === 'rejected' || outcome === 'cancelled' || outcome === 'unavailable') {
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

  interface PendingSessionOpen {
    requestId: string
    workspaceId: string
    sessionId: string
    deliveredAt?: number
    timer: ReturnType<typeof setTimeout>
    resolve: (accepted: boolean) => void
  }

  const pendingSessionOpens = new Map<string, PendingSessionOpen>()

  const settlePendingSessionOpen = (requestId: string, accepted: boolean): boolean => {
    const pending = pendingSessionOpens.get(requestId)
    if (pending === undefined) return false
    clearTimeout(pending.timer)
    pendingSessionOpens.delete(requestId)
    pending.resolve(accepted)
    return true
  }

  const requestSessionOpen = (workspaceId: string, sessionId: string): Promise<boolean> => {
    const requestId = randomUUID()
    return new Promise<boolean>(resolve => {
      const timer = setTimeout(() => {
        pendingSessionOpens.delete(requestId)
        resolve(false)
      }, 8_000)
      pendingSessionOpens.set(requestId, {
        requestId,
        workspaceId,
        sessionId,
        timer,
        resolve,
      })
    })
  }

  const optionalService = (name: string): unknown =>
    (ctx as unknown as { get?: (name: string, strict?: boolean) => unknown }).get?.(name, false)

  const requireWorkspaceSession = (workspaceId: string, sessionId: string): void => {
    const workspace = ctx.workspaceRegistry.get(workspaceId as never)
    if (workspace === undefined || !workspace.sessionIds.some(candidate => String(candidate) === sessionId)) {
      throw new Error(`session "${sessionId}" is not attached to workspace "${workspaceId}"`)
    }
  }

  const resolveAgent = async (sessionId: string): Promise<unknown> => {
    const controller = ctx.sessionController as unknown as {
      resolveAgent?: (id: string) => Promise<{ agent?: unknown; error?: unknown }>
    }
    if (typeof controller.resolveAgent !== 'function') throw new Error('Harness agent resolution is unavailable')
    const result = await controller.resolveAgent(sessionId)
    if (result.error !== undefined) throw result.error
    if (result.agent === undefined) throw new Error('Harness agent is unavailable')
    return result.agent
  }

  const optionalCapabilities = (): string[] => {
    const resolveAvailable = typeof (ctx.sessionController as unknown as { resolveAgent?: unknown }).resolveAgent === 'function'
    const files = optionalService('sessionFileReferences') as { list?: unknown } | undefined
    const skills = optionalService('sessionSkillCatalog') as { list?: unknown } | undefined
    const commands = optionalService('commands') as { list?: unknown } | undefined
    return [
      ...(resolveAvailable && typeof files?.list === 'function' ? ['fileCandidates'] : []),
      ...(resolveAvailable && typeof skills?.list === 'function' && typeof commands?.list === 'function' ? ['skillCandidates'] : []),
      ...(typeof (ctx.sessionController as unknown as { projections?: unknown }).projections === 'function' ? ['taskPreview'] : []),
    ]
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
    openSession: async request => {
      const workspace = ctx.workspaceRegistry.get(request.workspaceId as never)
      if (workspace === undefined) throw new Error(`workspace "${request.workspaceId}" not found`)
      if (!workspace.sessionIds.some(candidate => String(candidate) === request.sessionId)) {
        throw new Error(`session "${request.sessionId}" is not attached to workspace "${request.workspaceId}"`)
      }
      if (!await requestSessionOpen(request.workspaceId, request.sessionId)) {
        const error = new Error('Harness client did not acknowledge the session open')
        Object.assign(error, { code: 'desktop-client-unavailable' })
        throw error
      }
      return { accepted: true as const, sessionId: request.sessionId }
    },
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
    capabilities: optionalCapabilities,
    fileCandidates: async ({ workspaceId, sessionId, query }) => {
      requireWorkspaceSession(workspaceId, sessionId)
      const files = optionalService('sessionFileReferences') as {
        list: (agent: unknown, query: string, signal: AbortSignal) => Promise<readonly { path: string; kind: 'file' | 'directory' }[]>
      } | undefined
      if (files === undefined) throw new Error('Harness file reference service is unavailable')
      return { candidates: await files.list(await resolveAgent(sessionId), query, AbortSignal.timeout(15_000)) }
    },
    skillCandidates: async ({ workspaceId, sessionId }) => {
      requireWorkspaceSession(workspaceId, sessionId)
      const catalog = optionalService('sessionSkillCatalog') as {
        list: (request: { sessionId: string }, signal: AbortSignal) => Promise<{ skills: readonly { name: string; description: string }[] }>
      } | undefined
      const commands = optionalService('commands') as { list: (agent: unknown) => readonly { name: string }[] } | undefined
      if (catalog === undefined || commands === undefined) throw new Error('Harness skill or command service is unavailable')
      const agent = await resolveAgent(sessionId)
      const [listed, commandList] = await Promise.all([
        catalog.list({ sessionId }, AbortSignal.timeout(15_000)),
        Promise.resolve(commands.list(agent)),
      ])
      const names = new Set(commandList.map(command => command.name))
      return { skills: listed.skills.map(skill => ({ name: skill.name, description: skill.description, conflict: names.has(skill.name) })) }
    },
    taskPreview: async ({ workspaceId, sessionId }) => {
      requireWorkspaceSession(workspaceId, sessionId)
      const result = await ctx.sessionController.projections({ sessionId: sessionId as never }, AbortSignal.timeout(15_000)) as unknown as {
        kind?: string; values?: { turnOutline?: unknown }
      } | null
      if (result?.kind === 'migration-required') return { status: 'migration-required' as const }
      const outline = result?.values?.turnOutline
      if (!Array.isArray(outline)) return { status: 'unsupported' as const }
      const last = outline.at(-1) as { response?: unknown } | undefined
      if (typeof last?.response !== 'string' || last.response.trim() === '') return { status: 'empty' as const }
      return { status: 'available' as const, text: last.response }
    },
    snapshotFor: async sessionId => {
      const snapshot = snapshotForSession(sessionId)
      let task: DshPetTask | undefined
      try {
        task = (await refreshTaskSnapshot?.(5_000))?.find(candidate => candidate.sessionId === sessionId)
      } catch (error) {
        console.warn(`[dsh-pet] unable to confirm session state: ${String(error)}`)
      }
      if (task !== undefined) return snapshotForTask(task)
      unconfirmedSessions.add(sessionId)
      return { ...snapshot, taskRunning: true, message: '无法确认任务状态，暂不可发送' }
    },
  }, instance.commandSocketPath, instance)

  refreshTaskSnapshot = async (timeoutMs = 15_000): Promise<readonly DshPetTask[]> => {
    const listed = await ctx.sessionController.list({}, AbortSignal.timeout(timeoutMs))
    taskSnapshot = tasksFromSummaries(listed.items)
    commandBridge?.publishTasks(taskSnapshot)
    for (const task of taskSnapshot) {
      if (unconfirmedSessions.delete(task.sessionId)) {
        commandBridge?.publish(task.sessionId, snapshotForTask(task))
      }
    }
    return taskSnapshot
  }

  ctx.effect(() => {
    const projections = optionalService('sessionProjections') as {
      onChanged?: (listener: (session: Session, key: string) => void) => () => void
    } | undefined
    const dispose = projections?.onChanged?.((session, key) => {
      if (key === 'turnOutline') commandBridge?.publishTaskPreviewChange(String(session.id))
    })
    return () => { dispose?.() }
  }, 'dsh-pet: reply projection updates')

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

  const sessionOpenPendingRoute: WebRoute = {
    kind: 'exact',
    path: '/api/dsh-pet/session-open/pending',
    handler: (req: IncomingMessage, res: ServerResponse): void => {
      if (req.method !== 'GET') {
        json(res, 405, { ok: false, error: 'method-not-allowed' })
        return
      }
      const now = Date.now()
      const pending = [...pendingSessionOpens.values()].find(candidate =>
        candidate.deliveredAt === undefined || now - candidate.deliveredAt > 2_000)
      if (pending === undefined) {
        json(res, 200, { request: null })
        return
      }
      pending.deliveredAt = now
      json(res, 200, {
        request: {
          requestId: pending.requestId,
          workspaceId: pending.workspaceId,
          sessionId: pending.sessionId,
        },
      })
    },
  }

  const sessionOpenAckRoute: WebRoute = {
    kind: 'exact',
    path: '/api/dsh-pet/session-open/ack',
    handler: async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
      if (req.method !== 'POST') {
        json(res, 405, { ok: false, error: 'method-not-allowed' })
        return
      }
      let body = ''
      for await (const chunk of req) {
        body += String(chunk)
        if (Buffer.byteLength(body) > 4_096) {
          json(res, 413, { ok: false, error: 'request-too-large' })
          return
        }
      }
      let requestId: unknown
      try {
        requestId = JSON.parse(body).requestId
      } catch {
        requestId = undefined
      }
      if (typeof requestId !== 'string' || requestId === '') {
        json(res, 400, { ok: false, error: 'invalid-request' })
        return
      }
      if (!settlePendingSessionOpen(requestId, true)) {
        json(res, 404, { ok: false, error: 'unknown-request' })
        return
      }
      json(res, 200, { ok: true })
    },
  }

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

  let installationCheck: ReturnType<typeof detectHostApp> | undefined
  const installationRoute: WebRoute = {
    kind: 'exact',
    path: '/api/dsh-pet/install-status',
    handler: async (req, res): Promise<void> => {
      // Named webServer routes have no global authentication; use Harness's fence.
      let connection: { requestRejection?: (request: IncomingMessage) => number | undefined } | undefined
      try {
        connection = ctx.get('connection') as typeof connection
      } catch {
        json(res, 503, { status: 'unknown' })
        return
      }
      if (typeof connection?.requestRejection !== 'function') {
        json(res, 503, { status: 'unknown' })
        return
      }
      let rejection: number | undefined
      try {
        rejection = connection.requestRejection(req)
      } catch {
        json(res, 503, { status: 'unknown' })
        return
      }
      if (rejection !== undefined) {
        res.writeHead(rejection)
        res.end()
        return
      }
      if (req.method !== 'GET') {
        json(res, 405, { ok: false, error: 'method-not-allowed' })
        return
      }
      installationCheck ??= detectHostApp().finally(() => { installationCheck = undefined })
      const status = await installationCheck
      res.setHeader('cache-control', 'no-store')
      json(res, 200, { status })
    },
  }

  // Keep the former endpoint during the package rename so an older desktop
  // app can finish its upgrade without losing the status bridge.
  const legacyStatusRoute: WebRoute = { ...statusRoute, path: '/api/moodball/status' }

  // Route is always live: unlike the web water ball there is no settings
  // namespace, so nothing can take it down while the plugin is loaded.
  ctx.effect(() => {
    const dispose = ctx.webServer.register(statusRoute)
    const disposeInstallation = ctx.webServer.register(installationRoute)
    const disposeLegacy = ctx.webServer.register(legacyStatusRoute)
    const disposePending = ctx.webServer.register(sessionOpenPendingRoute)
    const disposeAck = ctx.webServer.register(sessionOpenAckRoute)
    return () => {
      disposeAck()
      disposePending()
      for (const pending of pendingSessionOpens.values()) {
        clearTimeout(pending.timer)
        pending.resolve(false)
      }
      pendingSessionOpens.clear()
      disposeLegacy()
      disposeInstallation()
      dispose()
    }
  }, 'dsh-pet: status and session-open routes')
}
