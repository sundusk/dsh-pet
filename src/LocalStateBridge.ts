import { randomUUID } from 'node:crypto'
import { connect, createServer, type Server, type Socket } from 'node:net'
import { chmodSync, existsSync, lstatSync, mkdirSync, renameSync, unlinkSync, type Stats } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

/** The newline-delimited local bridge payload shared with DSH Pet.app. */
export interface MoodBridgePayload {
  instanceId?: string
  state: string
  mood: string
  sessionId?: string
  workspaceId?: string
  taskRunning: boolean
  waitingForUser: boolean
  failed: boolean
  completed: boolean
  tool?: string
  message?: string
  updatedAt: number
}

/**
 * Small, opt-in local transport for the host plugin.
 *
 * The socket is deliberately a server owned by the plugin: DSH Pet only
 * observes it and never starts or stops Harness. Each client receives the
 * latest snapshot immediately, then one JSON object per line on change.
 */
export class LocalStateBridge {
  static defaultPath = join(homedir(), 'Library', 'Application Support', 'DSH Pet', 'dsh-pet.sock')

  private readonly socketPath: string
  private readonly readSnapshot: () => MoodBridgePayload
  private server: Server | undefined
  private clients = new Set<Socket>()
  private ownsSocket = false
  private probeGeneration = 0
  private probing = false
  private socketIdentity: SocketIdentity | undefined

  constructor(
    readSnapshot: () => MoodBridgePayload,
    socketPath = process.env.DSH_PET_SOCKET_PATH
      ?? process.env.MOODBALL_SOCKET_PATH
      ?? LocalStateBridge.defaultPath,
  ) {
    this.readSnapshot = readSnapshot
    this.socketPath = socketPath
  }

  start(onReady?: () => void): void {
    if (this.server || this.probing) return
    mkdirSync(dirname(this.socketPath), { recursive: true })

    if (existsSync(this.socketPath)) {
      const stat = lstatSync(this.socketPath)
      if (!stat.isSocket()) {
        console.warn(`[dsh-pet] local bridge path is not a socket: ${this.socketPath}`)
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
        console.warn(`[dsh-pet] local bridge path is already active: ${this.socketPath}`)
      })
      probe.once('error', error => {
        probe.destroy()
        this.probing = false
        if (generation !== this.probeGeneration) return
        const code = 'code' in error ? (error as Error & { code?: string }).code : undefined
        if (code !== 'ECONNREFUSED' && code !== 'ENOENT') {
          console.warn(`[dsh-pet] local bridge unavailable: ${error.message}`)
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
    const server = createServer((client) => {
      this.clients.add(client)
      client.setNoDelay(true)
      client.on('close', () => this.clients.delete(client))
      client.on('error', () => this.clients.delete(client))
      this.write(client)
    })
    server.on('error', (error) => {
      console.warn(`[dsh-pet] local bridge unavailable: ${error.message}`)
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

  publish(): void {
    for (const client of this.clients) this.write(client)
  }

  stop(): void {
    this.probeGeneration += 1
    this.probing = false
    for (const client of this.clients) client.destroy()
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

  private write(client: Socket): void {
    if (!client.destroyed) client.write(`${JSON.stringify(this.readSnapshot())}\n`)
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
