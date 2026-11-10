import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { test } from 'node:test'
import vm from 'node:vm'

test('browser half polls pending opens, navigates the workspace, and acknowledges', async () => {
  const code = await readFile(new URL('../lib/client.js', import.meta.url), 'utf8')
  let registration
  const previousWindow = globalThis.window
  const previousDocument = globalThis.document
  const previousFetch = globalThis.fetch
  const opened = []
  const acked = []
  globalThis.window = { __ModuleLoader__: { load(value) { registration = value } } }
  globalThis.document = { baseURI: 'http://127.0.0.1:4321/' }
  globalThis.fetch = async (url, init = {}) => {
    if (url.endsWith('/api/dsh-pet/session-open/pending')) {
      return { ok: true, async json() { return { request: { requestId: 'request-1', workspaceId: 'workspace-1', sessionId: 'session-1' } } } }
    }
    if (url.endsWith('/api/dsh-pet/session-open/ack')) {
      acked.push(JSON.parse(init.body))
      return { ok: true, async json() { return { ok: true } } }
    }
    throw new Error(`unexpected request: ${url}`)
  }
  try {
    vm.runInThisContext(code, { filename: 'client.js' })
    assert.equal(registration.id, 'dsh-mac-pet')
    const exports = registration.factory(() => { throw new Error('client must not require modules') })
    assert.deepEqual(exports.inject, ['uiWorkspace'])

    let cleanup
    exports.apply({
      uiWorkspace: { openSession(sessionId) { opened.push(sessionId) } },
      effect(callback) { cleanup = callback() },
    })
    const deadline = Date.now() + 1_500
    while (opened.length === 0 && Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 10))
    }
    assert.deepEqual(opened, ['session-1'])
    assert.deepEqual(acked, [{ requestId: 'request-1' }])
    cleanup()
  } finally {
    if (previousWindow === undefined) delete globalThis.window
    else globalThis.window = previousWindow
    if (previousDocument === undefined) delete globalThis.document
    else globalThis.document = previousDocument
    if (previousFetch === undefined) delete globalThis.fetch
    else globalThis.fetch = previousFetch
  }
})
