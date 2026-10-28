import assert from 'node:assert/strict'
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { createServer } from 'node:net'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

const installScript = await readFile(new URL('../install.sh', import.meta.url), 'utf8')
const pluginStart = installScript.indexOf('plugin_is_installed() {')
const pluginEnd = installScript.indexOf('\n}\n', pluginStart) + 2
assert.ok(pluginStart >= 0 && pluginEnd > pluginStart, 'installer plugin helper must remain extractable')
const pluginSource = installScript.slice(pluginStart, pluginEnd)
const helperStart = installScript.indexOf('instance_manifest_record() {')
const helperEnd = installScript.indexOf('\nstatus_is_active() {', helperStart)
assert.ok(helperStart >= 0 && helperEnd > helperStart, 'installer socket helper block must remain extractable')
const helperSource = installScript.slice(helperStart, helperEnd)

function runPluginProbe(inventory, queryFails = false) {
  const result = spawnSync('bash', ['-c', `${pluginSource}\nharness_cli() {\n  if [ "${'${PLUGIN_QUERY_FAIL}'}" = 1 ]; then return 1; fi\n  printf '%s' "${'${PLUGIN_INVENTORY}'}"\n}\nplugin_is_installed`], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PLUGIN_NAME: '@sundusk/dsh-pet',
      LEGACY_PLUGIN_NAME: '@sundusk/dsh-moodball-status',
      PLUGIN_PROFILE: 'web',
      PLUGIN_INVENTORY: inventory,
      PLUGIN_QUERY_FAIL: queryFails ? '1' : '0',
    },
  })
  assert.equal(result.error, undefined, result.error?.message)
  return result.status
}

test('installer distinguishes current, legacy, absent, and unavailable plugin states', () => {
  assert.equal(runPluginProbe('installed: @sundusk/dsh-pet'), 0)
  assert.equal(runPluginProbe('installed: @sundusk/dsh-moodball-status'), 3)
  assert.equal(runPluginProbe('installed: another-plugin'), 1)
  assert.equal(runPluginProbe('', true), 2)
})

function runSocketProbe({ home, socketPath, pid, type, running = '1', path }) {
  const result = spawnSync('bash', ['-c', `${helperSource}\nsocket_is_active`], {
    encoding: 'utf8',
    env: {
      ...process.env,
      HOME: home,
      SOCKET_PATH: socketPath,
      HARNESS_PID: pid,
      HARNESS_TYPE: type,
      HARNESS_RUNNING: running,
      DSH_PET_INSTANCE_DIRECTORY: join(home, 'Library', 'Application Support', 'DSH Pet', 'instances'),
      ...(path === undefined ? {} : { PATH: path }),
    },
  })
  assert.equal(result.error, undefined, result.error?.message)
  return result.status
}

async function listen(path) {
  const server = createServer(socket => socket.destroy())
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(path, resolve)
  })
  return server
}

test('installer discovers a matching instance manifest and both active sockets', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-pet-installer-'))
  const home = join(root, 'home')
  const socketRoot = join(root, 'sockets')
  const instances = join(home, 'Library', 'Application Support', 'DSH Pet', 'instances')
  await mkdir(instances, { recursive: true })
  await mkdir(socketRoot)
  const statusSocketPath = join(socketRoot, 'status.sock')
  const commandSocketPath = join(socketRoot, 'command.sock')
  const status = await listen(statusSocketPath)
  const command = await listen(commandSocketPath)
  try {
    await writeFile(join(instances, 'matching.json'), JSON.stringify({
      protocolVersion: 1,
      instanceId: 'matching',
      kind: 'desktop',
      pid: process.pid,
      startedAt: Math.floor(Date.now() / 1000),
      statusSocketPath,
      commandSocketPath,
    }))
    assert.equal(runSocketProbe({
      home,
      socketPath: join(root, 'legacy.sock'),
      pid: String(process.pid),
      type: 'desktop',
    }), 0)
    if (process.platform === 'darwin') {
      assert.equal(runSocketProbe({
        home,
        socketPath: join(root, 'legacy.sock'),
        pid: String(process.pid),
        type: 'desktop',
        path: '/usr/bin:/bin:/usr/sbin:/sbin',
      }), 0, 'macOS plutil fallback should discover manifests without Node')
    }
  } finally {
    await new Promise(resolve => status.close(resolve))
    await new Promise(resolve => command.close(resolve))
    await rm(root, { recursive: true, force: true })
  }
})

test('installer does not claim an active manifest belonging to another PID', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-pet-installer-'))
  const home = join(root, 'home')
  const socketRoot = join(root, 'sockets')
  const instances = join(home, 'Library', 'Application Support', 'DSH Pet', 'instances')
  await mkdir(instances, { recursive: true })
  await mkdir(socketRoot)
  const statusSocketPath = join(socketRoot, 'status.sock')
  const commandSocketPath = join(socketRoot, 'command.sock')
  const status = await listen(statusSocketPath)
  const command = await listen(commandSocketPath)
  try {
    await writeFile(join(instances, 'other.json'), JSON.stringify({
      protocolVersion: 1,
      instanceId: 'other',
      kind: 'desktop',
      pid: process.pid + 1,
      startedAt: Math.floor(Date.now() / 1000),
      statusSocketPath,
      commandSocketPath,
    }))
    assert.notEqual(runSocketProbe({
      home,
      socketPath: join(root, 'legacy.sock'),
      pid: String(process.pid),
      type: 'desktop',
    }), 0)
  } finally {
    await new Promise(resolve => status.close(resolve))
    await new Promise(resolve => command.close(resolve))
    await rm(root, { recursive: true, force: true })
  }
})

test('installer keeps detecting a reachable legacy socket', async () => {
  const root = await mkdtemp(join(tmpdir(), 'dsh-pet-installer-'))
  const home = join(root, 'home')
  const legacySocket = join(root, 'legacy.sock')
  const server = await listen(legacySocket)
  try {
    assert.equal(runSocketProbe({
      home,
      socketPath: legacySocket,
      pid: '',
      type: 'source',
    }), 0)
  } finally {
    await new Promise(resolve => server.close(resolve))
    await rm(root, { recursive: true, force: true })
  }
})
