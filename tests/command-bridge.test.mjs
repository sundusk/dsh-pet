import assert from 'node:assert/strict'
import { mkdtemp, rm, stat } from 'node:fs/promises'
import { connect } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { CommandBridge } from '../lib/index.js'

const snapshot = {
  state: 'thinking',
  mood: 'waiting',
  sessionId: 'dsh-pet-session-test',
  workspaceId: 'workspace-test',
  taskRunning: true,
  waitingForUser: false,
  failed: false,
  completed: false,
  updatedAt: 1,
}

function waitForServer(path) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 2_000
    const attempt = () => {
      const socket = connect(path)
      const onError = () => {
        socket.destroy()
        if (Date.now() >= deadline) reject(new Error('command socket did not start'))
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

function readLines(socket) {
  let buffer = ''
  const waiting = []
  socket.setEncoding('utf8')
  socket.on('data', chunk => {
    buffer += chunk
    while (true) {
      const newline = buffer.indexOf('\n')
      if (newline < 0) return
      const line = buffer.slice(0, newline)
      buffer = buffer.slice(newline + 1)
      if (line.trim() !== '') waiting.shift()?.(JSON.parse(line))
    }
  })
  return () => new Promise(resolve => waiting.push(resolve))
}

function send(socket, nextLine, id, action, fields = {}) {
  socket.write(`${JSON.stringify({ id, action, ...fields })}\n`)
  return nextLine()
}

test('command bridge serves capabilities, subscription snapshots, and serialized prompt commands', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-pet-command-'))
  const socketPath = join(root, 'command.sock')
  let active = 0
  let maxActive = 0
  const prompts = []
  const bridge = new CommandBridge({
    imageAttachmentLimits: imageLimits(),
    listWorkspaces: async () => [{
      id: 'workspace-test', title: 'Test', path: root, status: 'ok', sessionIds: [],
    }],
    listTasks: async () => [{
      sessionId: snapshot.sessionId,
      workspaceId: snapshot.workspaceId,
      title: 'Task',
      updatedAt: 1,
      running: true,
      blank: false,
      state: 'thinking',
      mood: 'waiting',
      taskRunning: true,
      waitingForUser: false,
      failed: false,
      completed: false,
    }],
    createSession: async request => ({ sessionId: request.sessionId }),
    prompt: async request => {
      active += 1
      maxActive = Math.max(maxActive, active)
      await new Promise(resolve => setTimeout(resolve, 20))
      active -= 1
      prompts.push(request)
      return { accepted: true, sessionId: request.sessionId }
    },
    snapshotFor: () => snapshot,
  }, socketPath)
  bridge.start()

  const socket = await waitForServer(socketPath)
  const nextLine = readLines(socket)
  const capabilities = await send(socket, nextLine, 'cap', 'capabilities')
  assert.equal(capabilities.ok, true)
  assert.deepEqual(capabilities.supports, [
    'workspaces', 'tasks', 'subscribeTasks', 'unsubscribeTasks',
    'createSession', 'prompt', 'imageAttachments', 'subscribe', 'unsubscribe',
  ])
  assert.deepEqual(capabilities.attachmentLimits, imageLimits())
  assert.ok(capabilities.maxCommandBytes > imageLimits().maxMessageImageBytes)

  const listed = await send(socket, nextLine, 'list', 'workspaces')
  assert.equal(listed.workspaces[0].title, 'Test')

  const tasks = await send(socket, nextLine, 'tasks', 'tasks')
  assert.equal(tasks.tasks[0].title, 'Task')

  const subscribedTasks = await send(socket, nextLine, 'tasks-sub', 'subscribeTasks')
  assert.equal(subscribedTasks.tasks[0].sessionId, snapshot.sessionId)

  const subscribed = await send(socket, nextLine, 'sub', 'subscribe', { sessionId: snapshot.sessionId })
  assert.deepEqual(subscribed.snapshot, snapshot)

  const promptA = send(socket, nextLine, 'prompt-a', 'prompt', {
    workspaceId: snapshot.workspaceId, sessionId: snapshot.sessionId, requestId: 'request-a', text: 'A',
  })
  const promptB = send(socket, nextLine, 'prompt-b', 'prompt', {
    workspaceId: snapshot.workspaceId, sessionId: snapshot.sessionId, requestId: 'request-b', text: 'B',
  })
  assert.equal((await promptA).accepted, true)
  assert.equal((await promptB).accepted, true)
  assert.equal(maxActive, 1)
  assert.deepEqual(prompts.map(prompt => prompt.requestId), ['request-a', 'request-b'])

  const imageOnly = await send(socket, nextLine, 'prompt-image', 'prompt', {
    workspaceId: snapshot.workspaceId,
    sessionId: snapshot.sessionId,
    requestId: 'request-image',
    text: '',
    images: [{ mediaType: 'image/png', data: 'aGVsbG8=', name: 'capture.png' }],
  })
  assert.equal(imageOnly.accepted, true)
  assert.deepEqual(prompts.at(-1).images, [
    { mediaType: 'image/png', data: 'aGVsbG8=', name: 'capture.png' },
  ])

  bridge.publish(snapshot.sessionId, { ...snapshot, mood: 'done', state: 'completed', taskRunning: false })
  const event = await nextLine()
  assert.equal(event.event, 'status')
  assert.equal(event.snapshot.mood, 'done')

  bridge.publishTasks(subscribedTasks.tasks)
  const taskEvent = await nextLine()
  assert.equal(taskEvent.event, 'tasks')
  assert.equal(taskEvent.tasks[0].title, 'Task')

  const permissions = (await stat(socketPath)).mode & 0o777
  assert.equal(permissions, 0o600)

  socket.destroy()
  bridge.stop()
  await rm(root, { recursive: true, force: true })
})

test('command bridge rejects malformed JSON without taking down the socket', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-pet-command-invalid-'))
  const socketPath = join(root, 'command.sock')
  const bridge = new CommandBridge({
    imageAttachmentLimits: imageLimits(),
    listWorkspaces: async () => [],
    listTasks: async () => [],
    createSession: async request => ({ sessionId: request.sessionId }),
    prompt: async request => ({ accepted: true, sessionId: request.sessionId }),
    snapshotFor: () => undefined,
  }, socketPath)
  bridge.start()
  const socket = await waitForServer(socketPath)
  const nextLine = readLines(socket)
  socket.write('not-json\n')
  const invalid = await nextLine()
  assert.equal(invalid.ok, false)
  assert.equal(invalid.error.code, 'invalid-json')
  const capabilities = await send(socket, nextLine, 'cap', 'capabilities')
  assert.equal(capabilities.ok, true)
  socket.destroy()
  bridge.stop()
  await rm(root, { recursive: true, force: true })
})

test('command bridge enforces deployment image limits and remains usable after oversized input', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-pet-command-images-'))
  const socketPath = join(root, 'command.sock')
  const bridge = new CommandBridge({
    imageAttachmentLimits: imageLimits({ maxImageBytes: 4, maxImagesPerMessage: 2, maxMessageImageBytes: 3 }),
    listWorkspaces: async () => [],
    listTasks: async () => [],
    createSession: async request => ({ sessionId: request.sessionId }),
    prompt: async request => {
      if (request.requestId === 'server-error') {
        const error = new Error('Model does not support image input.')
        error.code = 'session/attachment-invalid'
        throw error
      }
      return { accepted: true, sessionId: request.sessionId }
    },
    snapshotFor: () => undefined,
  }, socketPath)
  bridge.start()
  const socket = await waitForServer(socketPath)
  const nextLine = readLines(socket)
  const fields = {
    workspaceId: 'workspace-test', sessionId: 'session-test', requestId: 'request-test', text: '',
  }

  const tooMany = await send(socket, nextLine, 'many', 'prompt', {
    ...fields,
    images: [
      { mediaType: 'image/png', data: 'YQ==' },
      { mediaType: 'image/png', data: 'Yg==' },
      { mediaType: 'image/png', data: 'Yw==' },
    ],
  })
  assert.equal(tooMany.error.code, 'session/attachment-invalid')
  assert.match(tooMany.error.message, /image-count limit/)

  const tooLarge = await send(socket, nextLine, 'large', 'prompt', {
    ...fields,
    images: [{ mediaType: 'image/png', data: 'YWJjZQ==' }],
  })
  assert.equal(tooLarge.error.code, 'session/attachment-invalid')
  assert.match(tooLarge.error.message, /image-byte limit/)

  const invalidBase64 = await send(socket, nextLine, 'base64', 'prompt', {
    ...fields,
    images: [{ mediaType: 'image/png', data: 'not base64' }],
  })
  assert.equal(invalidBase64.error.code, 'session/attachment-invalid')
  assert.match(invalidBase64.error.message, /canonical base64/)

  const aggregateTooLarge = await send(socket, nextLine, 'aggregate', 'prompt', {
    ...fields,
    images: [
      { mediaType: 'image/png', data: 'YWI=' },
      { mediaType: 'image/png', data: 'Y2Q=' },
    ],
  })
  assert.equal(aggregateTooLarge.error.code, 'session/attachment-invalid')
  assert.match(aggregateTooLarge.error.message, /aggregate image-byte limit/)

  const serverError = await send(socket, nextLine, 'server', 'prompt', {
    ...fields,
    requestId: 'server-error',
    images: [{ mediaType: 'image/png', data: 'YQ==' }],
  })
  assert.equal(serverError.error.code, 'session/attachment-invalid')
  assert.equal(serverError.error.message, 'Model does not support image input.')

  // Reject before a newline arrives so an attacker cannot grow the buffer
  // without bound, then resynchronize at the next NDJSON delimiter.
  socket.write('x'.repeat(1024 * 1024 + 16))
  const oversized = await nextLine()
  assert.equal(oversized.error.code, 'request-too-large')
  socket.write('\n')
  const capabilities = await send(socket, nextLine, 'cap', 'capabilities')
  assert.equal(capabilities.ok, true)

  socket.destroy()
  bridge.stop()
  await rm(root, { recursive: true, force: true })
})

function imageLimits(overrides = {}) {
  return {
    maxImageBytes: 20,
    maxImagesPerMessage: 2,
    maxMessageImageBytes: 30,
    maxImagePixels: 100,
    maxImageDimension: 10,
    mediaTypes: ['image/png', 'image/jpeg'],
    ...overrides,
  }
}
