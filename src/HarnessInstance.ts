import { createHash, randomUUID } from 'node:crypto'
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export type HarnessInstanceKind = 'desktop' | 'web' | 'unknown'

/** The on-disk discovery contract consumed by MoodBall.app. */
export interface HarnessInstanceDescriptor {
  protocolVersion: 1
  instanceId: string
  kind: HarnessInstanceKind
  profile?: string
  /** Stable hash of a known Harness profile/home target; never the raw path. */
  targetId?: string
  pid: number
  startedAt: number
  webURL?: string
  statusSocketPath: string
  commandSocketPath: string
}

export const INSTANCE_PROTOCOL_VERSION = 1 as const

const MAX_UNIX_SOCKET_PATH_BYTES = 103

interface HarnessContextHints {
  name?: unknown
  profile?: unknown
  kind?: unknown
  type?: unknown
  profileContext?: { name?: unknown; dir?: unknown; home?: unknown }
  resolvedProfile?: { profile?: unknown }
  dir?: unknown
  profileDir?: unknown
  home?: unknown
  webServer?: {
    getOrigin?: () => string
    protocol?: unknown
    host?: unknown
    hostname?: unknown
    port?: unknown
  }
  get?: (name: string, strict?: boolean) => unknown
}

/**
 * Build a per-plugin identity. The plugin gets no reliable process-name based
 * signal, so kind stays unknown unless the host supplies an explicit profile or
 * kind. This avoids presenting a guessed Desktop/Web label in the settings UI.
 */
export function createHarnessInstanceDescriptor(context?: unknown): HarnessInstanceDescriptor {
  const hints = context as HarnessContextHints | undefined
  const profileValue = firstNonEmptyString(
    process.env.MOODBALL_PROFILE,
    process.env.DSH_PROFILE,
    hints?.profileContext?.name,
    hints?.profile,
    hints?.resolvedProfile?.profile,
    profileFromArgv(),
    readServiceString(hints, 'profile'),
    readServiceObject(hints, 'profileContext')?.name,
  )
  const profile = profileValue ?? profileName(hints?.resolvedProfile?.profile)
  const explicitKind = normalizeKind(firstNonEmptyString(
    process.env.MOODBALL_HARNESS_KIND,
    process.env.MOODBALL_HARNESS_TYPE,
    hints?.kind,
    hints?.type,
    readServiceString(hints, 'harnessKind'),
  ))
  const kind: HarnessInstanceKind = explicitKind
    ?? (profile === 'desktop' ? 'desktop' : profile === 'web' ? 'web' : 'unknown')
  const instanceId = randomUUID().replaceAll('-', '').slice(0, 12)
  const uid = typeof process.getuid === 'function' ? process.getuid() : process.pid
  const socketDir = join('/tmp', `dsh-pet-${uid}`)
  mkdirSync(socketDir, { recursive: true, mode: 0o700 })
  chmodSync(socketDir, 0o700)

  const statusSocketPath = join(socketDir, `${instanceId}-s.sock`)
  const commandSocketPath = join(socketDir, `${instanceId}-c.sock`)
  assertSocketPath(statusSocketPath)
  assertSocketPath(commandSocketPath)

  const webURL = safeLoopbackURL(
    process.env.MOODBALL_WEB_URL
      ?? process.env.DSH_WEB_URL
      ?? contextOrigin(hints)
      ?? contextWebURL(hints),
  )
  const targetId = targetIdentity(profile, hints)
  return {
    protocolVersion: INSTANCE_PROTOCOL_VERSION,
    instanceId,
    kind,
    ...(profile === undefined ? {} : { profile }),
    ...(targetId === undefined ? {} : { targetId }),
    pid: process.pid,
    startedAt: Math.floor(Date.now() / 1000),
    ...(webURL === undefined ? {} : { webURL }),
    statusSocketPath,
    commandSocketPath,
  }
}

/** Refresh the origin after WebServer has finished listening. */
export function refreshHarnessInstanceWebURL(descriptor: HarnessInstanceDescriptor, context?: unknown): boolean {
  const hints = context as HarnessContextHints | undefined
  const webURL = safeLoopbackURL(contextOrigin(hints) ?? contextWebURL(hints))
  if (webURL === undefined) return false
  descriptor.webURL = webURL
  return true
}

/** The default discovery directory shared by Desktop and Web Harness hosts. */
export function instanceDiscoveryDirectory(home = homedir()): string {
  return join(home, 'Library', 'Application Support', 'MoodBall', 'instances')
}

export function instanceManifestPath(instanceId: string, home = homedir()): string {
  return join(instanceDiscoveryDirectory(home), `${instanceId}.json`)
}

/** Publishes and removes only the manifest belonging to one generated identity. */
export class HarnessInstanceManifest {
  private published = false

  constructor(
    private readonly descriptor: HarnessInstanceDescriptor,
    private readonly directory = instanceDiscoveryDirectory(),
  ) {}

  get path(): string {
    return join(this.directory, `${this.descriptor.instanceId}.json`)
  }

  publish(): void {
    mkdirSync(this.directory, { recursive: true, mode: 0o700 })
    const temporary = `${this.path}.${process.pid}.${randomUUID()}.tmp`
    writeFileSync(temporary, `${JSON.stringify(this.descriptor)}\n`, { mode: 0o600 })
    chmodSync(temporary, 0o600)
    renameSync(temporary, this.path)
    chmodSync(this.path, 0o600)
    this.published = true
  }

  remove(): void {
    if (!this.published || !existsSync(this.path)) return
    try {
      const current = JSON.parse(readFileSync(this.path, 'utf8')) as { instanceId?: unknown }
      if (current.instanceId !== this.descriptor.instanceId) return
      unlinkSync(this.path)
      this.published = false
    } catch {
      // A concurrently removed or replaced manifest is not ours to delete.
    }
  }
}

function firstNonEmptyString(...values: readonly unknown[]): string | undefined {
  return values.find(value => typeof value === 'string' && value.trim() !== '') as string | undefined
}

function normalizeKind(value: string | undefined): HarnessInstanceKind | undefined {
  if (value === 'desktop' || value === 'web' || value === 'unknown') return value
  return undefined
}

function readServiceString(context: HarnessContextHints | undefined, name: string): string | undefined {
  try {
    return context?.get?.(name, false) as string | undefined
  } catch {
    return undefined
  }
}

function readServiceObject(context: HarnessContextHints | undefined, name: string): HarnessContextHints | undefined {
  try {
    const value = context?.get?.(name, false)
    return value !== null && typeof value === 'object' ? value as HarnessContextHints : undefined
  } catch {
    return undefined
  }
}

function profileFromArgv(): string | undefined {
  const args = process.argv.slice(1)
  const flag = args.indexOf('--profile')
  const value = flag >= 0 ? args[flag + 1] : undefined
  return value !== undefined && value !== '' && !value.startsWith('-') ? value : undefined
}

function contextOrigin(context: HarnessContextHints | undefined): string | undefined {
  try {
    return context?.webServer?.getOrigin?.()
  } catch {
    return undefined
  }
}

function contextWebURL(context: HarnessContextHints | undefined): string | undefined {
  const server = context?.webServer
  if (server === undefined) return undefined
  const protocol = typeof server.protocol === 'string' ? server.protocol : undefined
  const host = firstNonEmptyString(server.host, server.hostname)
  const port = typeof server.port === 'number' && Number.isInteger(server.port) ? server.port : undefined
  if (protocol === undefined || host === undefined || port === undefined) return undefined
  return `${protocol}//${host}:${port}`
}

function profileName(value: unknown): string | undefined {
  if (value === null || typeof value !== 'object') return undefined
  const name = (value as { name?: unknown }).name
  return typeof name === 'string' && name.trim() !== '' ? name : undefined
}

function targetIdentity(profile: string | undefined, context: HarnessContextHints | undefined): string | undefined {
  const explicit = firstNonEmptyString(process.env.MOODBALL_TARGET_ID, readServiceString(context, 'targetId'))
  if (explicit !== undefined) return explicit
  const profileContext = readServiceObject(context, 'profileContext')
  const profileObject = context?.resolvedProfile?.profile
  const profileDir = firstNonEmptyString(
    context?.profileContext?.dir,
    profileContext?.dir,
    context?.profileDir,
    profileObject !== null && typeof profileObject === 'object'
      ? (profileObject as { dir?: unknown }).dir
      : undefined,
  )
  const home = firstNonEmptyString(process.env.DSH_HOME, context?.profileContext?.home, profileContext?.home, context?.home)
  const source = profileDir ?? (home !== undefined && profile !== undefined ? `${home}\u0000${profile}` : undefined)
  if (source === undefined) return undefined
  return `target-${createHash('sha256').update(source).digest('hex').slice(0, 16)}`
}

function safeLoopbackURL(value: string | undefined): string | undefined {
  if (value === undefined) return undefined
  try {
    const url = new URL(value)
    if (!['http:', 'https:'].includes(url.protocol)) return undefined
    if (!['127.0.0.1', 'localhost', '[::1]', '::1'].includes(url.hostname)) return undefined
    if (url.username !== '' || url.password !== '' || url.search !== '' || url.hash !== '') return undefined
    if (url.pathname !== '' && url.pathname !== '/') return undefined
    return url.origin
  } catch {
    return undefined
  }
}

function assertSocketPath(path: string): void {
  if (Buffer.byteLength(path) > MAX_UNIX_SOCKET_PATH_BYTES) {
    throw new Error(`MoodBall instance socket path exceeds Unix limit: ${path}`)
  }
}
