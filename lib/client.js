window.__ModuleLoader__.load({
  id: "@sundusk/dsh-pet",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
/**
 * DSH Pet browser half: poll the host-side session-open queue and navigate the
 * Harness web client to the Session selected by the desktop pet.
 *
 * This file is wrapped into the DSH client-module loader format by
 * scripts/build-client.mjs. It has no runtime package imports: the only
 * required Cordis service is `uiWorkspace`.
 */
const inject = ['uiWorkspace']

function apply(ctx) {
  if (typeof fetch !== 'function' || typeof document === 'undefined') return

  let stopped = false
  let timer

  const endpoint = path => new URL(path, document.baseURI).href

  const acknowledge = async requestId => {
    await fetch(endpoint('api/dsh-pet/session-open/ack'), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ requestId }),
      cache: 'no-store',
    })
  }

  const poll = async () => {
    if (stopped) return
    try {
      const response = await fetch(endpoint('api/dsh-pet/session-open/pending'), {
        cache: 'no-store',
        headers: { accept: 'application/json' },
      })
      if (response.ok) {
        const payload = await response.json()
        const request = payload?.request
        if (request !== null && typeof request === 'object' && typeof request.sessionId === 'string' && typeof request.requestId === 'string') {
          try {
            ctx.uiWorkspace.openSession(request.sessionId)
            await acknowledge(request.requestId)
          } catch (error) {
            console.warn('[dsh-pet] unable to open the selected Harness Session:', error)
          }
        }
      }
    } catch {
      // The host or its protocol carrier can be briefly unavailable while the
      // desktop app starts or reloads; the next poll retries.
    }
    if (!stopped) timer = setTimeout(() => { void poll() }, 400)
  }

  ctx.effect(() => {
    void poll()
    return () => {
      stopped = true
      if (timer !== undefined) clearTimeout(timer)
    }
  }, 'dsh-pet: session open polling')
}

exports.inject = inject
exports.apply = apply

    return module.exports;
  },
});
