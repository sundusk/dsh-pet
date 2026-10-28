import assert from 'node:assert/strict'
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises'
import { connect } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

function waitForServer(path) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 2_000
    const attempt = () => {
      const socket = connect(path)
      const onError = () => {
        socket.destroy()
        if (Date.now() >= deadline) reject(new Error('plugin command socket did not start'))
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

async function waitForManifest(directory) {
  const deadline = Date.now() + 2_000
  while (Date.now() < deadline) {
    try {
      const names = await readdir(directory)
      for (const name of names) {
        if (!name.endsWith('.json')) continue
        const descriptor = JSON.parse(await readFile(join(directory, name), 'utf8'))
        if (descriptor.pid === process.pid && descriptor.protocolVersion === 1) return descriptor
      }
    } catch {
      // The plugin publishes only after both sockets are listening.
    }
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  throw new Error('plugin instance manifest did not start')
}

function nextJsonLine(socket) {
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

async function command(socket, nextLine, id, action, fields = {}) {
  socket.write(`${JSON.stringify({ id, action, ...fields })}\n`)
  return nextLine()
}

test('plugin adapter calls official-style workspace and session services', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-pet-plugin-'))
  const instanceDirectory = join(root, 'instances')
  const statusPath = join(root, 'status.sock')
  const commandPath = join(root, 'command.sock')
  const previousStatusPath = process.env.DSH_PET_SOCKET_PATH
  const previousCommandPath = process.env.DSH_PET_COMMAND_SOCKET_PATH
  const previousInstanceDirectory = process.env.DSH_PET_INSTANCE_DIRECTORY
  process.env.DSH_PET_SOCKET_PATH = statusPath
  process.env.DSH_PET_COMMAND_SOCKET_PATH = commandPath
  process.env.DSH_PET_INSTANCE_DIRECTORY = instanceDirectory

  let eventHandler
  let statusRoute
  const routes = []
  const cleanups = []
  const calls = []
  let sessionRunning = false
  const workspace = {
    id: 'workspace-test',
    title: 'Test workspace',
    path: root,
    sessionIds: [],
    status: async () => 'ok',
  }
  const ctx = {
    attachments: {
      imageLimits: {
        maxImageBytes: 20,
        maxImagesPerMessage: 2,
        maxMessageImageBytes: 30,
        maxImagePixels: 100,
        maxImageDimension: 10,
        mediaTypes: ['image/png', 'image/jpeg'],
      },
    },
    workspaceRegistry: {
      list: () => [workspace],
      get: id => String(id) === workspace.id ? workspace : undefined,
    },
    sessionController: {
      create: async request => {
        workspace.sessionIds.push(request.sessionId)
        return { sessionId: request.sessionId }
      },
      list: async () => ({ items: workspace.sessionIds.map(sessionId => ({
        sessionId,
        updatedAt: 100,
        running: sessionRunning,
        blank: false,
        cwd: root,
      })).concat(workspace.sessionIds.length > 0 ? [{
        sessionId: 'internal-child',
        updatedAt: 101,
        running: true,
        blank: false,
        parentSessionId: workspace.sessionIds[0],
        origin: 'subagent',
        cwd: root,
      }] : []) }),
      prompt: async request => {
        calls.push(request)
        return { accepted: true }
      },
    },
    on: (event, handler) => {
      if (event === 'session/event') eventHandler = handler
    },
    effect: effect => {
      const cleanup = effect()
      if (typeof cleanup === 'function') cleanups.push(cleanup)
    },
    webServer: {
      register: route => {
        routes.push(route)
        if (route.path === '/api/dsh-pet/status') statusRoute = route
        return () => {}
      },
    },
  }

  try {
    const plugin = await import('../lib/index.js')
    plugin.apply(ctx)
    const instance = await waitForManifest(instanceDirectory)
    assert.equal(instance.kind, 'unknown')
    assert.equal(instance.statusSocketPath.endsWith('-s.sock'), true)
    assert.equal(instance.commandSocketPath.endsWith('-c.sock'), true)
    const socket = await waitForServer(instance.commandSocketPath)
    const nextLine = nextJsonLine(socket)

    const listed = await command(socket, nextLine, 'list', 'workspaces')
    assert.equal(listed.workspaces[0].id, workspace.id)

    const created = await command(socket, nextLine, 'create', 'createSession', {
      workspaceId: workspace.id,
      sessionId: 'dsh-pet-session-test',
    })
    assert.equal(created.sessionId, 'dsh-pet-session-test')

    const subscribed = await command(socket, nextLine, 'subscribe', 'subscribe', {
      sessionId: 'dsh-pet-session-test',
    })
    assert.equal(subscribed.snapshot.workspaceId, workspace.id)
    assert.equal(subscribed.snapshot.mood, 'idle')

    const taskSubscription = await command(socket, nextLine, 'tasks', 'subscribeTasks')
    assert.deepEqual(taskSubscription.tasks.map(task => task.sessionId), ['dsh-pet-session-test'])
    assert.equal(taskSubscription.tasks[0].sessionId, 'dsh-pet-session-test')
    assert.equal(taskSubscription.tasks[0].workspaceId, workspace.id)
    assert.equal(taskSubscription.tasks[0].state, 'idle')

    const prompted = await command(socket, nextLine, 'prompt', 'prompt', {
      workspaceId: workspace.id,
      sessionId: 'dsh-pet-session-test',
      requestId: 'request-test',
      text: 'hello',
    })
    assert.equal(prompted.accepted, true)
    assert.equal(calls[0].mode, 'queue')
    assert.deepEqual(calls[0].content, [{ type: 'text', text: 'hello' }])

    const imagePrompted = await command(socket, nextLine, 'prompt-image', 'prompt', {
      workspaceId: workspace.id,
      sessionId: 'dsh-pet-session-test',
      requestId: 'request-image',
      text: '',
      images: [{ mediaType: 'image/png', data: 'aGVsbG8=', name: 'capture.png' }],
    })
    assert.equal(imagePrompted.accepted, true)
    assert.deepEqual(calls[1].content, [{
      type: 'image', mediaType: 'image/png', data: 'aGVsbG8=', name: 'capture.png',
    }])

    sessionRunning = true
    eventHandler({ id: 'dsh-pet-session-test' }, { type: 'turn/start' })
    const event = await nextLine()
    assert.equal(event.event, 'status')
    assert.equal(event.snapshot.mood, 'waiting')
    assert.equal(event.snapshot.taskRunning, true)

    const taskEvent = await nextLine()
    assert.equal(taskEvent.event, 'tasks')
    assert.equal(taskEvent.tasks[0].mood, 'waiting')

    let routeBody
    assert.deepEqual(routes.map(route => route.path), ['/api/dsh-pet/status', '/api/moodball/status'])
    statusRoute.handler(
      { method: 'GET' },
      { writeHead: status => assert.equal(status, 200), end: body => { routeBody = JSON.parse(body) } },
    )
    assert.equal(routeBody.ok, true)
    assert.equal(routeBody.sessionId, 'dsh-pet-session-test')
    assert.equal(routeBody.instanceId, instance.instanceId)
    socket.destroy()
  } finally {
    for (const cleanup of cleanups.reverse()) cleanup()
    if (previousStatusPath === undefined) delete process.env.DSH_PET_SOCKET_PATH
    else process.env.DSH_PET_SOCKET_PATH = previousStatusPath
    if (previousCommandPath === undefined) delete process.env.DSH_PET_COMMAND_SOCKET_PATH
    else process.env.DSH_PET_COMMAND_SOCKET_PATH = previousCommandPath
    if (previousInstanceDirectory === undefined) delete process.env.DSH_PET_INSTANCE_DIRECTORY
    else process.env.DSH_PET_INSTANCE_DIRECTORY = previousInstanceDirectory
    await rm(root, { recursive: true, force: true })
  }
})
