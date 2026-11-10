import assert from 'node:assert/strict'
import { test } from 'node:test'

test('install status requires Harness request authorization and exposes no paths', async () => {
  const { apply } = await import('../lib/index.js')
  let route
  let connection
  let failServiceLookup = false
  const ctx = {
    on() {},
    get: () => {
      if (failServiceLookup) throw new Error('service unavailable')
      return connection
    },
    attachments: { imageLimits: {} },
    effect: (fn, label) => {
      if (label === 'dsh-pet: status and session-open routes') fn()
    },
    webServer: {
      register: entry => {
        if (entry.path === '/api/dsh-pet/install-status') route = entry
        return () => {}
      },
    },
  }
  apply(ctx)
  assert.ok(route)
  async function request(method = 'GET') {
    const result = { headers: {} }
    await route.handler({ method, headers: {} }, {
      writeHead: status => { result.status = status },
      setHeader: (name, value) => { result.headers[name] = value },
      end: body => { result.body = body === undefined ? undefined : JSON.parse(body) },
    })
    return result
  }

  assert.deepEqual(await request(), { status: 503, headers: {}, body: { status: 'unknown' } })
  failServiceLookup = true
  assert.deepEqual(await request(), { status: 503, headers: {}, body: { status: 'unknown' } })
  failServiceLookup = false
  connection = { requestRejection: () => { throw new Error('authentication unavailable') } }
  assert.deepEqual(await request(), { status: 503, headers: {}, body: { status: 'unknown' } })
  connection = { requestRejection: () => 401 }
  assert.deepEqual(await request(), { status: 401, headers: {}, body: undefined })
  connection = { requestRejection: () => 403 }
  assert.deepEqual(await request(), { status: 403, headers: {}, body: undefined })
  connection = { requestRejection: () => undefined }
  assert.equal((await request('POST')).status, 405)
  const actual = await request()
  assert.equal(actual.status, 200)
  assert.equal(actual.headers['cache-control'], 'no-store')
  assert.deepEqual(Object.keys(actual.body), ['status'])
  assert.ok(['installed', 'not-found', 'unknown'].includes(actual.body.status))
})
