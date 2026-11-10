/**
 * DSH Pet browser half: poll the host-side session-open queue and navigate the
 * Harness web client to the Session selected by the desktop pet.
 *
 * This file is wrapped into the DSH client-module loader format by
 * scripts/build-client.mjs. The installation panel uses the React instance
 * shared by the Harness shell and the optional slots service.
 */
const inject = ['uiWorkspace']

function apply(ctx) {
  if (typeof fetch !== 'function' || typeof document === 'undefined') return

  if (typeof ctx.inject === 'function') {
    ctx.inject(['slots', 'layout'], scope => {
      const React = require('react')
      const h = React.createElement
      const panelId = 'dsh-pet-install'
      // The desktop shell spawns its Host locally and exclusively forwards this origin to it.
      const localDesktop = window.location?.protocol === 'dsh-app:' && window.location?.hostname === 'app'
        && typeof window.dshDesktopBoot?.ready === 'function'
      let hostStatus = 'unknown'
      let stopped = false
      let requestId = 0
      const listeners = new Set()
      const subscribe = listener => { listeners.add(listener); return () => listeners.delete(listener) }
      const refreshStatus = async () => {
        const current = ++requestId
        let next = 'unknown'
        try {
          const response = await fetch(new URL('api/dsh-pet/install-status', document.baseURI).href, { cache: 'no-store', headers: { accept: 'application/json' } })
          const payload = response.ok ? await response.json() : null
          if (['installed', 'not-found'].includes(payload?.status)) next = payload.status
        } catch { /* Keep the installation entry available when detection fails. */ }
        if (stopped || current !== requestId || next === hostStatus) return
        hostStatus = next
        for (const listener of listeners) listener()
      }

      scope.effect(() => {
        void refreshStatus()
        const timer = setInterval(() => { void refreshStatus() }, 15_000)
        return () => { stopped = true; clearInterval(timer) }
      }, 'dsh-pet: app installation detection')

      function InstallIcon({ size }) {
        return h('svg', { width: size, height: size, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 1.7, 'aria-hidden': true },
          h('path', { d: 'M12 3v12m-4-4 4 4 4-4M5 17v3h14v-3', strokeLinecap: 'round', strokeLinejoin: 'round' }))
      }

      function InstallPage() {
        const status = React.useSyncExternalStore(subscribe, () => hostStatus)
        const hostLabel = status === 'installed' ? '已检测到 DSH Pet' : status === 'not-found' ? '未检测到 DSH Pet' : '无法确认'
        const section = { marginTop: '28px' }
        return h('main', { style: { height: '100%', overflow: 'auto', boxSizing: 'border-box', color: 'var(--dsw-alias-label-primary)', background: 'var(--dsw-alias-bg-base)' } },
          h('div', { style: { maxWidth: '864px', margin: '0 auto', padding: 'calc(28px + var(--dsh-frame-top-clearance, 0px)) clamp(24px, 4vw, 48px) 48px', lineHeight: 1.65, fontSize: '14px' } },
            h('h1', { style: { fontSize: '20px', lineHeight: '28px', fontWeight: 500, margin: 0 } }, '安装 DSH Pet 桌宠'),
            h('p', null, '安装桌面应用后，桌宠可以留在桌面显示 Harness 的任务状态。'),
            h('p', null, '系统要求：macOS 14 或更新版本，Apple 芯片 Mac。'),
            h('a', { href: 'https://github.com/sundusk/dsh-pet/releases/latest/download/DSH-Pet.app.zip', target: '_blank', rel: 'noopener noreferrer', style: { display: 'inline-block', padding: '8px 16px', borderRadius: '8px', background: 'var(--dsw-alias-accent, #4d76ff)', color: '#fff', textDecoration: 'none' } }, '下载 DSH Pet'),
            h('p', null, h('a', { href: 'https://github.com/sundusk/dsh-pet/releases/latest', target: '_blank', rel: 'noopener noreferrer' }, '下载失败？打开 GitHub Release 页面')),
            h('section', { style: section },
              h('h2', { style: { fontSize: '16px' } }, '安装步骤'),
              h('ol', { style: { paddingLeft: '22px' } },
                h('li', null, '下载并解压 DSH-Pet.app.zip。'),
                h('li', null, '将 DSH Pet.app 拖入「应用程序」文件夹，然后打开。'),
                h('li', null, '在桌宠的「设置」→「Harness 连接」中检查连接状态。'),
                h('li', null, '如果 Harness 提示需要重启才能加载插件，请在当前任务完成后重启。')),
              h('p', null, '首次打开时，如果 macOS 阻止运行，请根据系统提示在「系统设置」→「隐私与安全性」中处理。')),
            h('section', { style: section },
              h('h2', { style: { fontSize: '16px' } }, '安装状态'),
              h('p', { role: 'status' }, `${localDesktop ? '本机' : 'Harness 所在设备'}：${hostLabel}。`),
              localDesktop ? null : h('p', null, '无法确认你当前使用的设备是否就是 Harness 所在设备，请在本机检查 DSH Pet 是否已安装。'),
              h('button', { type: 'button', onClick: () => { void refreshStatus() } }, '重新检测'))))
      }

      scope.slots.inject('main', () => scope.slots.register({ name: 'main', key: panelId }, InstallPage))
      scope.slots.inject('sidebar.panellist', () => {
        let unregister
        const panelInfo = scope.layout?.panelInfo
        const canTrackPanel = typeof panelInfo?.getSnapshot === 'function' && typeof panelInfo?.subscribe === 'function'
        const update = () => {
          const visible = !localDesktop || hostStatus !== 'installed' || !canTrackPanel || panelInfo.getSnapshot().activePanelId === panelId
          if (visible && unregister === undefined) unregister = scope.slots.register({ name: 'sidebar.panellist', id: panelId, order: 90, label: '安装桌宠' }, InstallIcon)
          else if (!visible && unregister !== undefined) { unregister(); unregister = undefined }
        }
        const unlistenStatus = subscribe(update)
        const unlistenPanel = canTrackPanel ? panelInfo.subscribe(update) : () => {}
        update()
        return () => { unlistenStatus(); unlistenPanel(); unregister?.() }
      })
    })
  }

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
