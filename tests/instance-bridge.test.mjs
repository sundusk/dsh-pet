import assert from 'node:assert/strict'
import { mkdir, mkdtemp, readFile, stat, writeFile, rm } from 'node:fs/promises'
import { unlinkSync } from 'node:fs'
import { connect, createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import {
  CommandBridge,
  createHarnessInstanceDescriptor,
  HarnessInstanceManifest,
  LocalStateBridge,
  refreshHarnessInstanceWebURL,
} from '../lib/index.js'

const limits = {
  maxImageBytes: 20,
  maxImagesPerMessage: 2,
  maxMessageImageBytes: 30,
  maxImagePixels: 100,
  maxImageDimension: 10,
  mediaTypes: ['image/png'],
}

test('descriptor reads optional hints inside a real Cordis plugin context', async () => {
  const root = new Context()
  const profileContext = {
    name: 'desktop',
    dir: '/Users/example/.dsh/profiles/desktop',
    home: '/Users/example/.dsh',
  }
  let descriptor
  const plugin = { apply: ctx => { descriptor = createHarnessInstanceDescriptor(ctx) } }
  const withoutProfile = root.plugin(plugin)
  await withoutProfile
  assert.equal(descriptor.kind, 'unknown')
  assert.equal(descriptor.targetId, undefined)
  await withoutProfile.dispose()

  root.provide('profileContext', profileContext)
  const withProfile = root.plugin(plugin)
  try {
    await withProfile
    assert.equal(descriptor.kind, 'desktop')
    assert.equal(descriptor.profile, 'desktop')
    assert.equal(descriptor.targetId, createHarnessInstanceDescriptor({ profileContext }).targetId)
  } finally {
    await withProfile.dispose()
  }
})

test('descriptor uses explicit profile evidence and emits only loopback origins', () => {
  const desktop = createHarnessInstanceDescriptor({ profile: 'desktop' })
  assert.equal(desktop.kind, 'desktop')
  assert.equal(desktop.profile, 'desktop')
  const web = createHarnessInstanceDescriptor({
    profile: 'web',
    webServer: { protocol: 'http:', host: '127.0.0.1', port: 3080 },
  })
  assert.equal(web.kind, 'web')
  assert.equal(web.webURL, 'http://127.0.0.1:3080')
  const untrusted = createHarnessInstanceDescriptor({
    profile: 'web',
    webServer: { protocol: 'https:', host: '192.168.1.2', port: 3080 },
  })
  assert.equal(untrusted.webURL, undefined)
  assert.ok(untrusted.statusSocketPath.length < 104)
  assert.ok(untrusted.commandSocketPath.length < 104)

  const officialDesktopShape = createHarnessInstanceDescriptor({
    profileContext: {
      name: 'desktop',
      dir: '/Users/example/.dsh/profiles/desktop',
      home: '/Users/example/.dsh',
    },
    webServer: { getOrigin: () => 'http://127.0.0.1:43127' },
  })
  assert.equal(officialDesktopShape.kind, 'desktop')
  assert.equal(officialDesktopShape.profile, 'desktop')
  assert.equal(officialDesktopShape.webURL, 'http://127.0.0.1:43127')
  assert.match(officialDesktopShape.targetId, /^target-[0-9a-f]{16}$/)

  let listening = false
  const delayed = createHarnessInstanceDescriptor({
    profileContext: { name: 'web' },
    webServer: { getOrigin: () => {
      if (!listening) throw new Error('listener not bound')
      return 'http://127.0.0.1:43128'
    } },
  })
  assert.equal(delayed.webURL, undefined)
  assert.equal(refreshHarnessInstanceWebURL(delayed, {
    webServer: { getOrigin: () => { throw new Error('listener not bound') } },
  }), false)
  listening = true
  assert.equal(refreshHarnessInstanceWebURL(delayed, {
    webServer: { getOrigin: () => 'http://127.0.0.1:43128' },
  }), true)
  assert.equal(delayed.webURL, 'http://127.0.0.1:43128')
})

function descriptor(id, root) {
  return {
    protocolVersion: 1,
    instanceId: id,
    kind: 'unknown',
    pid: process.pid,
    startedAt: Math.floor(Date.now() / 1000),
    statusSocketPath: join(root, `${id}-s.sock`),
    commandSocketPath: join(root, `${id}-c.sock`),
  }
}

function handlers(instanceId) {
  const snapshot = {
    instanceId,
    state: 'idle',
    mood: 'idle',
    taskRunning: false,
    waitingForUser: false,
    failed: false,
    completed: false,
    updatedAt: 1,
  }
  return {
    imageAttachmentLimits: limits,
    listWorkspaces: async () => [],
    listTasks: async () => [],
    createSession: async request => ({ sessionId: request.sessionId }),
    prompt: async request => ({ accepted: true, sessionId: request.sessionId }),
    snapshotFor: () => snapshot,
  }
}

function waitForServer(path) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 2_000
    const attempt = () => {
      const socket = connect(path)
      const onError = () => {
        socket.destroy()
        if (Date.now() >= deadline) reject(new Error(`socket did not start: ${path}`))
        else setTimeout(attempt, 10)
      }
      socket.once('error', onError)
      socket.once('connect', () => {
        socket.off('error', onError)
        resolve(socket)
      })
    }
    attempt()
  })
}

function nextLine(socket) {
  let buffer = ''
  const waiters = []
  socket.setEncoding('utf8')
  socket.on('data', chunk => {
    buffer += chunk
    while (true) {
      const newline = buffer.indexOf('\n')
      if (newline < 0) return
      const line = buffer.slice(0, newline)
      buffer = buffer.slice(newline + 1)
      if (line.trim() !== '') waiters.shift()?.(JSON.parse(line))
    }
  })
  return () => new Promise(resolve => waiters.push(resolve))
}

async function capabilities(socket) {
  const next = nextLine(socket)
  socket.write('{"id":"cap","action":"capabilities"}\n')
  return next()
}

test('two instance bridges keep identities, sockets, and discovery manifests isolated', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-pet-instances-'))
  const discovery = join(root, 'instances')
  const first = descriptor('instance-first', root)
  const second = descriptor('instance-second', root)
  const firstManifest = new HarnessInstanceManifest(first, discovery)
  const secondManifest = new HarnessInstanceManifest(second, discovery)
  const firstBridge = new CommandBridge(handlers(first.instanceId), first.commandSocketPath, first)
  const secondBridge = new CommandBridge(handlers(second.instanceId), second.commandSocketPath, second)
  const firstStatus = new LocalStateBridge(() => handlers(first.instanceId).snapshotFor(), first.statusSocketPath)
  const secondStatus = new LocalStateBridge(() => handlers(second.instanceId).snapshotFor(), second.statusSocketPath)
  const unrelated = join(discovery, 'keep.txt')

  try {
    await mkdir(discovery, { recursive: true })
    await writeFile(unrelated, 'keep')
    firstBridge.start()
    secondBridge.start()
    firstStatus.start()
    secondStatus.start()
    const firstSocket = await waitForServer(first.commandSocketPath)
    const secondSocket = await waitForServer(second.commandSocketPath)
    firstManifest.publish()
    secondManifest.publish()

    const firstCapabilities = await capabilities(firstSocket)
    const secondCapabilities = await capabilities(secondSocket)
    assert.equal(firstCapabilities.instance.instanceId, first.instanceId)
    assert.equal(secondCapabilities.instance.instanceId, second.instanceId)
    assert.equal(firstCapabilities.instance.commandSocketPath, first.commandSocketPath)
    assert.equal(secondCapabilities.instance.commandSocketPath, second.commandSocketPath)
    assert.deepEqual(JSON.parse(await readFile(firstManifest.path, 'utf8')), first)
    assert.equal((await stat(firstManifest.path)).mode & 0o777, 0o600)

    firstManifest.remove()
    assert.equal(await stat(secondManifest.path).then(() => true), true)
    assert.equal(await readFile(unrelated, 'utf8'), 'keep')

    firstBridge.stop()
    firstStatus.stop()
    await waitForServerOnce(first.commandSocketPath)
    const stillAlive = await capabilities(secondSocket)
    assert.equal(stillAlive.instance.instanceId, second.instanceId)
  } finally {
    secondBridge.stop()
    secondStatus.stop()
    secondManifest.remove()
    await rm(root, { recursive: true, force: true })
  }
})

test('a legacy active socket is never unlinked by a competing bridge stop', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-pet-legacy-'))
  const socketPath = join(root, 'dsh-pet-command.sock')
  const first = new CommandBridge(handlers('legacy-owner'), socketPath)
  const contender = new CommandBridge(handlers('contender'), socketPath)
  try {
    first.start()
    const ownerSocket = await waitForServer(socketPath)
    contender.start()
    contender.stop()
    const response = await capabilities(ownerSocket)
    assert.equal(response.ok, true)
    assert.equal((await stat(socketPath)).isSocket(), true)
    ownerSocket.destroy()
  } finally {
    contender.stop()
    first.stop()
    await rm(root, { recursive: true, force: true })
  }
})

test('a legacy stale socket is reclaimed after a refused probe', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-pet-stale-'))
  const socketPath = join(root, 'dsh-pet-command.sock')
  const stale = createServer()
  const bridge = new CommandBridge(handlers('stale-reclaimed'), socketPath)
  try {
    await new Promise(resolve => stale.listen(socketPath, resolve))
    await new Promise(resolve => stale.close(resolve))
    bridge.start()
    const socket = await waitForServer(socketPath)
    const response = await capabilities(socket)
    assert.equal(response.instance, undefined)
    socket.destroy()
  } finally {
    bridge.stop()
    await rm(root, { recursive: true, force: true })
  }
})

test('stop does not unlink a replacement socket with a different inode', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-pet-replacement-'))
  const socketPath = join(root, 'dsh-pet-command.sock')
  const bridge = new CommandBridge(handlers('owner'), socketPath)
  const replacement = createServer()
  try {
    bridge.start()
    const ownerSocket = await waitForServer(socketPath)
    ownerSocket.destroy()
    unlinkSync(socketPath)
    await writeFile(join(root, 'inode-filler'), 'keep the old inode occupied')
    await new Promise(resolve => replacement.listen(socketPath, resolve))
    bridge.stop()
    assert.equal((await stat(socketPath)).isSocket(), true)
  } finally {
    bridge.stop()
    await new Promise(resolve => replacement.close(resolve))
    await rm(root, { recursive: true, force: true })
  }
})

function waitForServerOnce(path) {
  return new Promise((resolve, reject) => {
    const socket = connect(path)
    socket.once('connect', () => { socket.destroy(); reject(new Error('socket remained active')) })
    socket.once('error', () => { socket.destroy(); resolve() })
  })
}
