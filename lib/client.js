// Browser half of dsh-task-watcher-plugin: a Settings → Plugins tab with a
// start/stop switch for the standalone Windows tray watcher. Loaded through
// the web plugin loader (window.__ModuleLoader__); React comes from the
// platform module table. Talks to the Host half over /api/dsh-task-watcher/*.
//
// The switch reflects (and drives) the PROCESS state only — the watcher keeps
// its own independent lifecycle (desktop shortcut start, tray right-click
// exit, survives DSH restarts).
window.__ModuleLoader__.load({ id: '@yeqingtang/dsh-task-watcher-plugin', factory: (require) => {
  var module = { exports: {} }; var exports = module.exports;

  const React = require('react')
  const { useState, useEffect, useCallback } = React
  const h = React.createElement

  let LOCALE = 'en'
  try {
    const nl = (navigator.language || '').toLowerCase()
    if (nl.startsWith('zh')) LOCALE = 'zh'
  } catch (e) { /* keep en */ }

  const T = {
    zh: {
      title: '任务监视器',
      running: '运行中',
      stopped: '已停止',
      starting: '正在启动…',
      stopping: '正在停止…',
      version: '版本',
      pid: '进程',
      notDeployed: '未部署（点击开关安装并启动）',
      dataDir: '数据目录',
      refresh: '刷新',
      failed: '操作失败',
      hint1: '监视器是独立进程：可通过桌面快捷方式启动、托盘右键退出，DSH 重启不影响它。',
      hint2: '开关只控制进程启停；停止后 DSH 重启不会自动拉回（记住你的选择），重新打开开关即可恢复。停用/卸载本插件不会杀死正在运行的监视器。',
      loadFail: '状态获取失败',
    },
    en: {
      title: 'Task Watcher',
      running: 'Running',
      stopped: 'Stopped',
      starting: 'Starting…',
      stopping: 'Stopping…',
      version: 'Version',
      pid: 'PID',
      notDeployed: 'Not deployed (flip the switch to deploy & start)',
      dataDir: 'Data directory',
      refresh: 'Refresh',
      failed: 'Operation failed',
      hint1: 'The watcher is an independent process: start via desktop shortcut, exit via tray right-click; DSH restarts do not affect it.',
      hint2: 'The switch only controls the process. After a stop, DSH restarts will not bring the tray back (your choice is remembered) — flip the switch on to resume. Disabling/uninstalling this plugin never kills a running watcher.',
      loadFail: 'Failed to load status',
    },
  }
  const t = (k) => T[LOCALE][k] || k

  const API_TIMEOUT_MS = 20000
  async function api(action) {
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), API_TIMEOUT_MS)
    try {
      const r = await fetch('/api/dsh-task-watcher/' + action, { method: 'POST', signal: ctrl.signal })
      const body = await r.json()
      if (!r.ok) throw new Error((body && body.error) || ('HTTP ' + r.status))
      return body.result
    } finally {
      clearTimeout(timer)
    }
  }

  function TaskWatcherPanel() {
    const [status, setStatus] = useState(null)   // {running,pids,version,deployed,...}
    const [busy, setBusy] = useState(false)      // 'start' | 'stop' | null
    const [error, setError] = useState(null)

    const load = useCallback(async () => {
      try {
        setStatus(await api('status'))
        setError(null)
      } catch (e) {
        setError(t('loadFail') + ': ' + (e && e.message ? e.message : e))
      }
    }, [])

    useEffect(() => {
      load()
      const timer = setInterval(load, 10000)
      return () => clearInterval(timer)
    }, [load])

    const running = !!(status && status.running && status.pids && status.pids.length > 0)
    const working = busy === 'start' ? t('starting') : busy === 'stop' ? t('stopping') : null

    const toggle = async () => {
      if (busy) return
      const action = running ? 'stop' : 'start'
      setBusy(action)
      setError(null)
      try {
        await api(action)
      } catch (e) {
        setError(t('failed') + ': ' + (e && e.message ? e.message : e))
      } finally {
        setBusy(null)
        load()
      }
    }

    const dotClass = busy ? 'dtw-dot dtw-dot-busy' : running ? 'dtw-dot dtw-dot-on' : 'dtw-dot dtw-dot-off'

    return h('div', { className: 'dtw-panel' },
      h('div', { className: 'dtw-row-main' },
        h('span', { className: dotClass }),
        h('span', { className: 'dtw-state' },
          working || (running ? t('running') : (status && !status.deployed ? t('notDeployed') : t('stopped')))),
        h('span', { className: 'dtw-actions' },
          h('button', {
            type: 'button',
            className: 'dtw-switch' + (running || busy === 'start' ? ' dtw-switch-on' : ''),
            onClick: toggle,
            disabled: !!busy,
            role: 'switch',
            'aria-checked': running,
            title: running ? t('stopping') : t('starting'),
            'aria-label': running ? t('stopping') : t('starting'),
          },
            h('span', { className: 'dtw-knob' })),
          h('button', { type: 'button', className: 'dtw-refresh', onClick: load, title: t('refresh'), 'aria-label': t('refresh') },
            h('svg', { viewBox: '0 0 24 24', width: '14', height: '14', fill: 'currentColor', 'aria-hidden': 'true' },
              h('path', { d: 'M17.65 6.35A7.95 7.95 0 0 0 12 4a8 8 0 1 0 7.73 10h-2.08A6 6 0 1 1 12 6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z' }))),
        ),
      ),
      status ? h('dl', { className: 'dtw-meta' },
        running ? h('div', { className: 'dtw-meta-row' },
          h('dt', null, t('pid')), h('dd', null, status.pids.join(', '))) : null,
        status.version ? h('div', { className: 'dtw-meta-row' },
          h('dt', null, t('version')), h('dd', null, status.version)) : null,
        h('div', { className: 'dtw-meta-row' },
          h('dt', null, t('dataDir')), h('dd', { className: 'dtw-dir' }, status.dataDir)),
      ) : null,
      error ? h('div', { className: 'dtw-error' }, error) : null,
      h('div', { className: 'dtw-hints' },
        h('div', { className: 'dtw-hint' }, t('hint1')),
        h('div', { className: 'dtw-hint' }, t('hint2')),
      ),
    )
  }

  const DTW_CSS = `
.dtw-panel, .dtw-panel * { box-sizing: border-box; }
.dtw-panel { width: 100%; padding: 16px 0 8px; font-size: 13px; line-height: 1.5; }
.dtw-row-main { display: flex; align-items: center; gap: 10px; flex-wrap: nowrap; }
.dtw-state { font-weight: 600; flex: 1 1 auto; min-width: 0; }
.dtw-actions { display: inline-flex; align-items: center; gap: 10px; flex: none; margin-left: auto; }
.dtw-dot { width: 9px; height: 9px; border-radius: 50%; flex: none; display: inline-block; }
.dtw-dot-on { background: #22c55e; box-shadow: 0 0 6px #22c55e; }
.dtw-dot-off { background: #9ca3af; }
.dtw-dot-busy { background: #f59e0b; animation: dtw-pulse 1s ease-in-out infinite; }
@keyframes dtw-pulse { 50% { opacity: .35; } }
.dtw-panel .dtw-switch { all: unset; position: relative; display: inline-block; width: 40px; height: 22px; min-width: 40px; max-width: 40px; border-radius: 11px; border: 1px solid rgba(128,128,128,.45); background: rgba(128,128,128,.25); cursor: pointer; padding: 0; margin: 0; transition: background .18s ease; flex: none; }
.dtw-switch-on { background: #4d6bfe !important; border-color: #4d6bfe !important; }
.dtw-knob { position: absolute; top: 2px; left: 2px; width: 16px; height: 16px; border-radius: 50%; background: #fff; transition: left .18s ease; box-shadow: 0 1px 3px rgba(0,0,0,.35); display: block; }
.dtw-switch-on .dtw-knob { left: 20px; }
.dtw-panel .dtw-switch:disabled { opacity: .55; cursor: default; }
.dtw-panel .dtw-switch:focus-visible { outline: 2px solid #4d6bfe; outline-offset: 2px; }
.dtw-panel .dtw-refresh { all: unset; display: inline-flex; align-items: center; justify-content: center; width: 26px; height: 26px; min-width: 26px; border-radius: 6px; cursor: pointer; font-size: 15px; color: inherit; opacity: .6; padding: 0; margin: 0; flex: none; }
.dtw-panel .dtw-refresh:hover { opacity: 1; background: rgba(128,128,128,.15); }
.dtw-meta { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 4px 14px; margin: 12px 0 0; opacity: .8; font-size: 12px; }
.dtw-meta-row { display: contents; }
.dtw-meta dt { opacity: .75; white-space: nowrap; }
.dtw-meta dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }
.dtw-error { margin-top: 10px; color: #ef4444; font-size: 12px; }
.dtw-hints { margin-top: 14px; opacity: .6; font-size: 12px; display: grid; gap: 4px; }
.dtw-hint { position: relative; padding-left: 14px; }
.dtw-hint::before { content: '•'; position: absolute; left: 2px; opacity: .8; }
`

  const inject = ['slots']

  function apply(ctx) {
    const slots = ctx.get('slots')
    if (slots === undefined) return
    ctx.effect(() => {
      const id = 'dsh-task-watcher-style'
      if (!document.getElementById(id)) {
        const s = document.createElement('style')
        s.id = id
        s.textContent = DTW_CSS
        document.head.appendChild(s)
      }
      return () => { const el = document.getElementById(id); if (el) el.remove() }
    }, 'task-watcher-style')
    // NOTE: keep "register({" adjacent (no newline between) — the injector's
    // skeleton validator requires register\(\{\s*...name: '<known slot>'.
    slots.inject('settings.plugins.tab', () => slots.register({ name: 'settings.plugins.tab', id: 'task-watcher', order: 15, label: () => (LOCALE === 'zh' ? t('title') : 'Task Watcher') }, TaskWatcherPanel))
  }

  module.exports = { inject, apply }
  return module.exports
} })
