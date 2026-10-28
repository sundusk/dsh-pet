import { randomUUID } from 'node:crypto'
import { connect, createServer, type Server, type Socket } from 'node:net'
import { chmodSync, existsSync, lstatSync, mkdirSync, renameSync, unlinkSync, type Stats } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import type { PromptContentPart } from '@deepseek-ai/dsh-api-session-controller'
import type { MoodBridgePayload } from './LocalStateBridge.js'
import type { HarnessInstanceDescriptor } from './HarnessInstance.js'

type PromptImageMediaType = Extract<PromptContentPart, { type: 'image' }>['mediaType']

/** A detached workspace projection exposed to DSH Pet.app. */
export interface DshPetWorkspace {
  id: string
  title: string
  path: string
  status: 'ok' | 'missing-dir'
  sessionIds: readonly string[]
}

export interface CreateSessionCommand {
  workspaceId: string
  sessionId: string
}

export interface PromptCommand {
  workspaceId: string
  sessionId: string
  requestId: string
  text: string
  images: readonly PromptImage[]
}

export interface PromptImage {
  mediaType: PromptImageMediaType
  data: string
  name?: string
}

/** Deployment-resolved image admission policy exposed by Harness. */
export interface ImageAttachmentLimits {
  maxImageBytes: number
  maxImagesPerMessage: number
  maxMessageImageBytes: number
  maxImagePixels: number
  maxImageDimension: number
  mediaTypes: readonly string[]
}

/** A cold-safe ordinary Session projection for the task cards. */
export interface DshPetTask {
  sessionId: string
  workspaceId: string
  title: string
  cwd?: string
  updatedAt: number
  running: boolean
  blank: boolean
  state: 'disconnected' | 'idle' | 'thinking' | 'toolCalling' | 'waitingApproval' | 'waitingUserAnswer' | 'completed' | 'failed' | 'stopped'
  mood: string
  taskRunning: boolean
  waitingForUser: boolean
  failed: boolean
  completed: boolean
  tool?: string
  message?: string
}

export interface CommandHandlers {
  imageAttachmentLimits: ImageAttachmentLimits
  listWorkspaces: () => Promise<readonly DshPetWorkspace[]>
  listTasks: () => Promise<readonly DshPetTask[]>
  createSession: (request: CreateSessionCommand) => Promise<{ sessionId: string }>
  prompt: (request: PromptCommand) => Promise<{ accepted: true; sessionId: string }>
  snapshotFor: (sessionId: string) => MoodBridgePayload | undefined
}

interface ClientState {
  socket: Socket
  buffer: string
  bufferBytes: number
  discardingOversizedLine: boolean
  subscriptions: Set<string>
  taskSubscription: boolean
  operationTail: Promise<void>
}

interface CommandRequest {
  id?: unknown
  action?: unknown
  workspaceId?: unknown
  sessionId?: unknown
  requestId?: unknown
  text?: unknown
  images?: unknown
}

const COMMAND_METADATA_BYTES = 1024 * 1024

class CommandError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message)
    this.name = 'CommandError'
  }
}

/**
 * User-local command and session-status transport.
 *
 * This socket is intentionally separate from LocalStateBridge. Older DSH Pet
 * clients continue to receive the global read-only snapshot, while new
 * clients can issue authenticated-by-file-permission commands and subscribe
 * to one selected session without mixing command responses into that stream.
 */
export class CommandBridge {
  static defaultPath = join(homedir(), 'Library', 'Application Support', 'DSH Pet', 'dsh-pet-command.sock')

  private readonly socketPath: string
  private readonly handlers: CommandHandlers
  private readonly instance: HarnessInstanceDescriptor | undefined
  private readonly maxCommandBytes: number
  private server: Server | undefined
  private ownsSocket = false
  private clients = new Set<ClientState>()
  private probeGeneration = 0
  private probing = false
  private socketIdentity: SocketIdentity | undefined

  constructor(
    handlers: CommandHandlers,
    socketPath = process.env.DSH_PET_COMMAND_SOCKET_PATH
      ?? process.env.MOODBALL_COMMAND_SOCKET_PATH
      ?? CommandBridge.defaultPath,
    instance?: HarnessInstanceDescriptor,
  ) {
    this.handlers = handlers
    this.instance = instance
    this.socketPath = socketPath
    this.maxCommandBytes = maxCommandBytes(handlers.imageAttachmentLimits)
  }

  start(onReady?: () => void): void {
    if (this.server || this.probing) return
    mkdirSync(dirname(this.socketPath), { recursive: true })

    if (existsSync(this.socketPath)) {
      const stat = lstatSync(this.socketPath)
      if (!stat.isSocket()) {
        console.warn(`[dsh-pet] command bridge path is not a socket: ${this.socketPath}`)
        return
      }
      const staleIdentity = socketIdentity(this.socketPath)
      // Probe before reclaiming a legacy path. ECONNREFUSED means the Unix
      // socket is stale; a successful connection means another owner is live.
      const generation = ++this.probeGeneration
      this.probing = true
      const probe = connect(this.socketPath)
      probe.once('connect', () => {
        probe.destroy()
        this.probing = false
        console.warn(`[dsh-pet] command bridge path is already active: ${this.socketPath}`)
      })
      probe.once('error', error => {
        probe.destroy()
        this.probing = false
        if (generation !== this.probeGeneration) return
        const code = 'code' in error ? (error as Error & { code?: string }).code : undefined
        if (code !== 'ECONNREFUSED' && code !== 'ENOENT') {
          console.warn(`[dsh-pet] command bridge unavailable: ${error.message}`)
          return
        }
        if (!sameSocketIdentity(staleIdentity, socketIdentity(this.socketPath))) return
        try { unlinkSync(this.socketPath) } catch { /* another owner may have won the race */ }
        this.listen(onReady)
      })
      return
    }

    this.listen(onReady)
  }

  private listen(onReady?: () => void): void {
    const generation = this.probeGeneration
    const server = createServer(socket => {
      const client: ClientState = {
        socket,
        buffer: '',
        bufferBytes: 0,
        discardingOversizedLine: false,
        subscriptions: new Set(),
        taskSubscription: false,
        operationTail: Promise.resolve(),
      }
      this.clients.add(client)
      socket.setNoDelay(true)
      socket.setEncoding('utf8')
      socket.on('data', chunk => {
        let text = String(chunk)
        if (client.discardingOversizedLine) {
          const newline = text.indexOf('\n')
          if (newline < 0) return
          client.discardingOversizedLine = false
          text = text.slice(newline + 1)
        }
        client.buffer += text
        client.bufferBytes += Buffer.byteLength(text)
        this.consume(client)
      })
      socket.on('close', () => this.clients.delete(client))
      socket.on('error', () => this.clients.delete(client))
    })
    server.on('error', error => {
      console.warn(`[dsh-pet] command bridge unavailable: ${error.message}`)
    })
    server.listen(this.socketPath, () => {
      const identity = socketIdentity(this.socketPath)
      if (generation !== this.probeGeneration) {
        server.close()
        unlinkIfSame(this.socketPath, identity)
        return
      }
      this.ownsSocket = true
      this.socketIdentity = identity
      try { chmodSync(this.socketPath, 0o600) } catch { /* best effort */ }
      onReady?.()
    })
    this.server = server
  }

  /** Push a replacement snapshot to clients subscribed to this session. */
  publish(sessionId: string, snapshot: MoodBridgePayload): void {
    for (const client of this.clients) {
      if (!client.subscriptions.has(sessionId)) continue
      this.write(client.socket, {
        event: 'status',
        sessionId,
        snapshot,
      })
    }
  }

  /** Push a replacement task projection to clients that requested task updates. */
  publishTasks(tasks: readonly DshPetTask[]): void {
    for (const client of this.clients) {
      if (!client.taskSubscription) continue
      this.write(client.socket, { event: 'tasks', tasks })
    }
  }

  stop(): void {
    this.probeGeneration += 1
    this.probing = false
    for (const client of this.clients) client.socket.destroy()
    this.clients.clear()
    const server = this.server
    this.server = undefined
    if (!server) return
    const replacement = preserveReplacement(this.socketPath, this.socketIdentity)
    server.close()
    if (replacement !== undefined) {
      try { renameSync(replacement, this.socketPath) } catch { /* replacement was removed independently */ }
    } else if (this.ownsSocket) {
      unlinkIfSame(this.socketPath, this.socketIdentity)
    }
    this.ownsSocket = false
    this.socketIdentity = undefined
  }

  private consume(client: ClientState): void {
    while (true) {
      const newline = client.buffer.indexOf('\n')
      if (newline < 0) {
        if (client.bufferBytes > this.maxCommandBytes) {
          client.buffer = ''
          client.bufferBytes = 0
          client.discardingOversizedLine = true
          this.rejectOversizedRequest(client.socket)
        }
        return
      }
      const line = client.buffer.slice(0, newline)
      client.buffer = client.buffer.slice(newline + 1)
      client.bufferBytes -= Buffer.byteLength(`${line}\n`)
      if (line.trim() === '') continue
      if (Buffer.byteLength(line) > this.maxCommandBytes) {
        this.rejectOversizedRequest(client.socket)
        continue
      }
      client.operationTail = client.operationTail
        .then(() => this.handle(client, line))
        .catch(error => {
          this.write(client.socket, {
            id: null,
            ok: false,
            error: { code: 'internal-error', message: errorMessage(error) },
          })
        })
    }
  }

  private rejectOversizedRequest(socket: Socket): void {
    this.write(socket, {
      id: null,
      ok: false,
      error: { code: 'request-too-large', message: 'command request exceeds the deployment image limits' },
    })
  }

  private async handle(client: ClientState, line: string): Promise<void> {
    let request: CommandRequest
    try {
      request = JSON.parse(line) as CommandRequest
    } catch {
      this.write(client.socket, {
        id: null,
        ok: false,
        error: { code: 'invalid-json', message: 'request must be one JSON object per line' },
      })
      return
    }

    const id = typeof request.id === 'string' && request.id !== '' ? request.id : null
    const action = request.action
    try {
      if (action === 'capabilities') {
        this.respond(client.socket, id, {
          protocolVersion: 1,
          commandSocket: true,
          statusSubscription: true,
          supports: [
            'workspaces', 'tasks', 'subscribeTasks', 'unsubscribeTasks',
            'createSession', 'prompt', 'imageAttachments', 'subscribe', 'unsubscribe',
          ],
          attachmentLimits: this.handlers.imageAttachmentLimits,
          maxCommandBytes: this.maxCommandBytes,
          ...(this.instance === undefined ? {} : { instance: this.instance }),
        })
        return
      }
      if (action === 'workspaces') {
        this.respond(client.socket, id, { workspaces: await this.handlers.listWorkspaces() })
        return
      }
      if (action === 'tasks') {
        this.respond(client.socket, id, { tasks: await this.handlers.listTasks() })
        return
      }
      if (action === 'subscribeTasks') {
        client.taskSubscription = true
        this.respond(client.socket, id, { tasks: await this.handlers.listTasks() })
        return
      }
      if (action === 'unsubscribeTasks') {
        client.taskSubscription = false
        this.respond(client.socket, id, {})
        return
      }
      if (action === 'createSession') {
        const workspaceId = stringField(request.workspaceId, 'workspaceId')
        const sessionId = stringField(request.sessionId, 'sessionId')
        const result = await this.handlers.createSession({ workspaceId, sessionId })
        this.respond(client.socket, id, result)
        return
      }
      if (action === 'prompt') {
        const workspaceId = stringField(request.workspaceId, 'workspaceId')
        const sessionId = stringField(request.sessionId, 'sessionId')
        const requestId = stringField(request.requestId, 'requestId')
        const text = optionalStringField(request.text, 'text') ?? ''
        const images = imageFields(request.images, this.handlers.imageAttachmentLimits)
        if (text.trim() === '' && images.length === 0) {
          throw new CommandError('empty-prompt', 'prompt must include non-whitespace text or an image')
        }
        const result = await this.handlers.prompt({ workspaceId, sessionId, requestId, text, images })
        this.respond(client.socket, id, result)
        return
      }
      if (action === 'subscribe') {
        const sessionId = stringField(request.sessionId, 'sessionId')
        client.subscriptions.add(sessionId)
        this.respond(client.socket, id, {
          sessionId,
          snapshot: this.handlers.snapshotFor(sessionId) ?? null,
        })
        return
      }
      if (action === 'unsubscribe') {
        const sessionId = stringField(request.sessionId, 'sessionId')
        client.subscriptions.delete(sessionId)
        this.respond(client.socket, id, { sessionId })
        return
      }
      throw new CommandError('unknown-action', 'unsupported DSH Pet command')
    } catch (error) {
      this.write(client.socket, {
        id,
        ok: false,
        error: {
          code: commandErrorCode(error),
          message: errorMessage(error),
        },
      })
    }
  }

  private respond(socket: Socket, id: string | null, result: unknown): void {
    this.write(socket, { id, ok: true, ...asObject(result) })
  }

  private write(socket: Socket, payload: unknown): void {
    if (!socket.destroyed) socket.write(`${JSON.stringify(payload)}\n`)
  }
}

interface SocketIdentity {
  dev: number
  ino: number
}

function socketIdentity(path: string): SocketIdentity | undefined {
  try {
    const stat: Stats = lstatSync(path)
    return stat.isSocket() ? { dev: stat.dev, ino: stat.ino } : undefined
  } catch {
    return undefined
  }
}

function sameSocketIdentity(left: SocketIdentity | undefined, right: SocketIdentity | undefined): boolean {
  return left !== undefined && right !== undefined && left.dev === right.dev && left.ino === right.ino
}

function unlinkIfSame(path: string, identity: SocketIdentity | undefined): void {
  if (!sameSocketIdentity(identity, socketIdentity(path))) return
  try { unlinkSync(path) } catch { /* already removed */ }
}

function preserveReplacement(path: string, owner: SocketIdentity | undefined): string | undefined {
  if (owner === undefined) return undefined
  const current = socketIdentity(path)
  if (sameSocketIdentity(owner, current) || current === undefined) return undefined
  const backup = `${path}.dsh-pet-preserve-${randomUUID()}`
  try {
    renameSync(path, backup)
    return backup
  } catch {
    return undefined
  }
}

function stringField(value: unknown, name: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new CommandError('invalid-request', `${name} must be a non-empty string`)
  }
  return value
}

function optionalStringField(value: unknown, name: string): string | undefined {
  if (value === undefined) return undefined
  if (typeof value !== 'string') throw new CommandError('invalid-request', `${name} must be a string`)
  return value
}

function imageFields(value: unknown, limits: ImageAttachmentLimits): readonly PromptImage[] {
  if (value === undefined) return []
  if (!Array.isArray(value)) throw new CommandError('invalid-request', 'images must be an array')
  if (value.length > limits.maxImagesPerMessage) {
    throw new CommandError('session/attachment-invalid', 'Image batch exceeds the configured image-count limit.')
  }

  let aggregateBytes = 0
  return value.map((candidate, index) => {
    if (candidate === null || typeof candidate !== 'object' || Array.isArray(candidate)) {
      throw new CommandError('invalid-request', `images[${index}] must be an object`)
    }
    const image = candidate as Record<string, unknown>
    const mediaType = stringField(image.mediaType, `images[${index}].mediaType`)
    if (!limits.mediaTypes.includes(mediaType)) {
      throw new CommandError(
        'session/attachment-invalid',
        `Image type ${mediaType} is not accepted by this deployment.`,
      )
    }
    const data = stringField(image.data, `images[${index}].data`)
    const name = optionalStringField(image.name, `images[${index}].name`)
    const bytes = canonicalBase64Bytes(data)
    if (bytes > limits.maxImageBytes) {
      throw new CommandError('session/attachment-invalid', 'Image exceeds the configured image-byte limit.')
    }
    aggregateBytes += bytes
    if (aggregateBytes > limits.maxMessageImageBytes) {
      throw new CommandError('session/attachment-invalid', 'Image batch exceeds the configured aggregate image-byte limit.')
    }
    return { mediaType: mediaType as PromptImageMediaType, data, ...(name === undefined ? {} : { name }) }
  })
}

function canonicalBase64Bytes(data: string): number {
  if (data.length === 0 || data.length % 4 !== 0 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(data)) {
    throw new CommandError('session/attachment-invalid', 'Image upload is not canonical base64.')
  }
  const padding = data.endsWith('==') ? 2 : data.endsWith('=') ? 1 : 0
  return (data.length / 4) * 3 - padding
}

function maxCommandBytes(limits: ImageAttachmentLimits): number {
  const aggregateBytes = Math.min(
    limits.maxMessageImageBytes,
    limits.maxImageBytes * limits.maxImagesPerMessage,
  )
  const base64Bytes = Math.ceil(aggregateBytes / 3) * 4
  return Math.min(Number.MAX_SAFE_INTEGER, base64Bytes + COMMAND_METADATA_BYTES)
}

function commandErrorCode(error: unknown): string {
  if (error instanceof CommandError) return error.code
  if (error !== null && typeof error === 'object' && 'code' in error) {
    const code = (error as { code?: unknown }).code
    if (typeof code === 'string' && code !== '') return code
  }
  return 'command-failed'
}

function asObject(value: unknown): Record<string, unknown> {
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, unknown>
  }
  return { value }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
