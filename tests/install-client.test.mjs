import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { test } from 'node:test'
import vm from 'node:vm'

async function setup({ desktop = false, status = 'installed', activePanelId = null, panelInfoMode = 'available', deferManual = false } = {}) {
  const code = await readFile(new URL('../lib/client.js', import.meta.url), 'utf8')
  let registration
  const React = {
    createElement(type, props, ...children) { return { type, props: props ?? {}, children } },
    useSyncExternalStore(_subscribe, snapshot) { return snapshot() },
  }
  const requests = []
  let resolveManual
  const sandbox = {
    window: {
      __ModuleLoader__: { load(value) { registration = value } },
      location: desktop ? { protocol: 'dsh-app:', hostname: 'app' } : { protocol: 'http:', hostname: 'localhost' },
      ...(desktop ? { dshDesktopBoot: { ready() {} } } : {}),
    },
    document: { baseURI: 'http://localhost:3080/' }, URL,
    fetch: async url => {
      requests.push(url)
      if (deferManual && requests.length === 2) await new Promise(resolve => { resolveManual = resolve })
      return { ok: true, json: async () => ({ status }) }
    },
    setInterval() { return 1 }, clearInterval() {},
  }
  vm.runInNewContext(code, sandbox)
  const client = registration.factory(name => {
    assert.equal(name, 'react')
    return React
  })
  const slots = new Map(), cleanup = []
  let panelListener
  const panelInfo = {
    getSnapshot: () => ({ activePanelId }),
    subscribe(listener) { panelListener = listener; return () => {} },
  }
  client.apply({
    inject(services, callback) {
      assert.deepEqual(Array.from(services), ['slots', 'layout'])
      callback({
        layout: {
          panelInfo: panelInfoMode === 'missing' ? undefined : panelInfoMode === 'incomplete' ? {} : panelInfo,
          selectPanel(id) { activePanelId = id; panelListener?.() },
        },
        effect(fn) { cleanup.push(fn()) },
        slots: {
          inject(_name, register) { cleanup.push(register()) },
          register(options, component) {
            slots.set(options.name, { options, component })
            return () => slots.delete(options.name)
          },
        },
      })
    },
    effect() {},
  })
  await new Promise(resolve => setImmediate(resolve))
  return {
    slots, requests,
    setStatus(value) { status = value },
    setActive(id) { activePanelId = id; panelListener() },
    getActive() { return activePanelId },
    resolveManual() { resolveManual() },
    close() { cleanup.forEach(fn => fn?.()) },
  }
}

function flatten(node) {
  return typeof node === 'string' ? [node] : node && typeof node === 'object'
    ? [node, ...node.children.flatMap(flatten)] : []
}

test('web installation panel reports host status without claiming the browser device is local', async () => {
  const fixture = await setup()
  try {
    assert.equal(fixture.slots.get('sidebar.panellist').options.id, fixture.slots.get('main').options.key)
    const content = flatten(fixture.slots.get('main').component())
    assert.ok(content.includes('Harness 所在设备：已检测到 DSH Pet。'))
    assert.ok(content.includes('无法确认你当前使用的设备是否就是 Harness 所在设备，请在本机检查 DSH Pet 是否已安装。'))
    assert.ok(content.includes('系统要求：macOS 14 或更新版本，Apple 芯片 Mac。'))
    assert.ok(content.some(node => node?.type === 'a' && node.props.href === 'https://github.com/sundusk/dsh-mac-pet/releases/latest/download/DSH-Pet.app.zip'))
    assert.deepEqual(fixture.requests, ['http://localhost:3080/api/dsh-pet/install-status'])
    content.find(node => node?.type === 'button').props.onClick()
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(fixture.requests.length, 2)
    assert.match(fixture.requests[1], /\?refresh=1$/)
  } finally { fixture.close() }
})

test('installed desktop app hides entry only after leaving its panel', async () => {
  const fixture = await setup({ desktop: true, activePanelId: 'dsh-pet-install' })
  try {
    assert.ok(fixture.slots.has('sidebar.panellist'))
    assert.ok(flatten(fixture.slots.get('main').component()).includes('本机：已检测到 DSH Pet。'))
    fixture.setActive('plugins')
    assert.equal(fixture.slots.has('sidebar.panellist'), false)
    assert.ok(fixture.slots.has('main'))
  } finally { fixture.close() }
})

test('manual detection reports progress and success before completing the installation page', async () => {
  const fixture = await setup({ desktop: true, status: 'not-found', activePanelId: 'dsh-pet-install', deferManual: true })
  try {
    fixture.setStatus('installed')
    flatten(fixture.slots.get('main').component()).find(node => node?.type === 'button').props.onClick()
    let content = flatten(fixture.slots.get('main').component())
    assert.ok(content.includes('正在检测…'))
    assert.equal(content.find(node => node?.type === 'button').props.disabled, true)
    fixture.resolveManual()
    await new Promise(resolve => setImmediate(resolve))
    content = flatten(fixture.slots.get('main').component())
    assert.ok(content.includes('检测完成。本机：已检测到 DSH Pet。'))
    assert.ok(fixture.slots.has('sidebar.panellist'))
    content.find(node => node?.type === 'button' && node.children.includes('完成，返回会话')).props.onClick()
    assert.equal(fixture.getActive(), null)
    assert.equal(fixture.slots.has('sidebar.panellist'), false)
  } finally { fixture.close() }
})

test('manual detection reports an unchanged result and does not navigate after the user leaves', async () => {
  const fixture = await setup({ desktop: true, status: 'not-found', activePanelId: 'dsh-pet-install', deferManual: true })
  try {
    flatten(fixture.slots.get('main').component()).find(node => node?.type === 'button').props.onClick()
    fixture.setActive('plugins')
    fixture.resolveManual()
    await new Promise(resolve => setImmediate(resolve))
    const content = flatten(fixture.slots.get('main').component())
    assert.ok(content.includes('检测完成。本机：未检测到 DSH Pet。'))
    assert.equal(fixture.getActive(), 'plugins')
    assert.ok(fixture.slots.has('sidebar.panellist'))
  } finally { fixture.close() }
})

test('unknown desktop installation keeps entry available', async () => {
  const fixture = await setup({ desktop: true, status: 'unknown' })
  try { assert.ok(fixture.slots.has('sidebar.panellist')) } finally { fixture.close() }
})

test('desktop app not found keeps the installation entry and reports the result', async () => {
  const fixture = await setup({ desktop: true, status: 'not-found' })
  try {
    assert.ok(fixture.slots.has('sidebar.panellist'))
    assert.ok(flatten(fixture.slots.get('main').component()).includes('本机：未检测到 DSH Pet。'))
  } finally { fixture.close() }
})

test('older layouts without panel tracking retain the installation entry', async () => {
  for (const panelInfoMode of ['missing', 'incomplete']) {
    const fixture = await setup({ desktop: true, panelInfoMode })
    try {
      assert.ok(fixture.slots.has('sidebar.panellist'))
      assert.ok(flatten(fixture.slots.get('main').component()).includes('本机：已检测到 DSH Pet。'))
    } finally { fixture.close() }
  }
})
