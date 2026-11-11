import type { Socket } from 'node:net'
import { UnixSocketServer } from './UnixSocketServer.js'

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
  private readonly readSnapshot: () => MoodBridgePayload
  private readonly socketServer: UnixSocketServer
  private clients = new Set<Socket>()

  constructor(
    readSnapshot: () => MoodBridgePayload,
    socketPath: string,
  ) {
    this.readSnapshot = readSnapshot
    this.socketServer = new UnixSocketServer({
      socketPath,
      label: 'local bridge',
      onConnection: client => {
        this.clients.add(client)
        client.setNoDelay(true)
        client.on('close', () => this.clients.delete(client))
        client.on('error', () => this.clients.delete(client))
        this.write(client)
      },
      onStop: () => {
        for (const client of this.clients) client.destroy()
        this.clients.clear()
      },
    })
  }

  start(onReady?: () => void): void {
    this.socketServer.start(onReady)
  }

  publish(): void {
    for (const client of this.clients) this.write(client)
  }

  stop(): void {
    this.socketServer.stop()
  }

  private write(client: Socket): void {
    if (!client.destroyed) client.write(`${JSON.stringify(this.readSnapshot())}\n`)
  }
}
