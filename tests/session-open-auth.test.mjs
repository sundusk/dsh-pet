import assert from 'node:assert/strict'
import { test } from 'node:test'

test('session-open queue applies the Harness request-authorization fence', async () => {
  const { apply } = await import('../lib/index.js')
  const routes = new Map()
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
        routes.set(entry.path, entry)
        return () => {}
      },
    },
  }
  apply(ctx)

  const pending = routes.get('/api/dsh-pet/session-open/pending')
  const ack = routes.get('/api/dsh-pet/session-open/ack')
  assert.ok(pending)
  assert.ok(ack)

  function response() {
    const result = { headers: {} }
    return {
      result,
      writeHead(status) { result.status = status },
      setHeader(name, value) { result.headers[name] = value },
      end(body) { result.body = body === undefined ? undefined : JSON.parse(body) },
    }
  }

  async function request(route, method = 'GET') {
    const res = response()
    const req = {
      method,
      headers: {},
      async *[Symbol.asyncIterator]() {
        yield JSON.stringify({ requestId: 'missing-request' })
      },
    }
    await route.handler(req, res)
    return res.result
  }

  assert.deepEqual(await request(pending), {
    status: 503,
    headers: {},
    body: { ok: false, error: 'authorization-unavailable' },
  })

  failServiceLookup = true
  assert.equal((await request(pending)).status, 503)
  failServiceLookup = false

  connection = { requestRejection: () => { throw new Error('authentication unavailable') } }
  assert.equal((await request(pending)).status, 503)

  connection = { requestRejection: () => 401 }
  assert.deepEqual(await request(pending), { status: 401, headers: {}, body: undefined })
  assert.deepEqual(await request(ack, 'POST'), { status: 401, headers: {}, body: undefined })

  connection = { requestRejection: () => 403 }
  assert.equal((await request(ack, 'POST')).status, 403)

  connection = { requestRejection: () => undefined }
  assert.deepEqual(await request(pending), {
    status: 200,
    headers: {},
    body: { request: null },
  })
  assert.deepEqual(await request(ack, 'POST'), {
    status: 404,
    headers: {},
    body: { ok: false, error: 'unknown-request' },
  })
})
