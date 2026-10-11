// shogun-status: pure parsing and formatting. No I/O here, so every function is testable on plain strings.
//
// Rule for every parser: when the file does not have the shape we expect, return { ok: false }
// and let the display show '?'. Never fall back to 0 - a silent 0 looks like "all clear".

// The only agents the display counts. Names such as test_* in queue/inbox are never looked at.
export const AGENTS = [
  { name: 'shogun', label: '将' },
  { name: 'karo', label: '家' },
  { name: 'gunshi', label: '軍' },
  { name: 'ashigaru1', label: '足1' },
  { name: 'ashigaru2', label: '足2' },
  { name: 'ashigaru3', label: '足3' },
  { name: 'ashigaru4', label: '足4' },
  { name: 'ashigaru5', label: '足5' },
  { name: 'ashigaru6', label: '足6' },
  { name: 'ashigaru7', label: '足7' },
]

// cmd status values that mean "finished". Everything else must be a known in-progress value, or the item is '?'.
const CMD_TERMINAL = /^(done|done_with_caveat|(superseded|cancelled|failed)_\S+)$/
const CMD_ACTIVE = new Set(['pending', 'in_progress', 'assigned', 'blocked'])

// task status -> one-character state shown in the band
const TASK_STATE = {
  assigned: '稼',
  in_progress: '稼',
  blocked: '塞',
  pending: '待',
  idle: '休',
  done: '済',
  completed: '済',
  failed: '失',
}

// A scalar after "key:" - strip a trailing " # comment" and surrounding quotes. null when it is not a plain one-line scalar.
function scalar(raw) {
  let v = raw.trim()
  const hash = v.search(/\s#/)
  if (hash >= 0) v = v.slice(0, hash).trim()
  const q = v.match(/^(['"])(.*)\1$/)
  if (q) v = q[2]
  if (v === '' || /^[|>\[{&*!%@`]/.test(v) || /^['"]/.test(v)) return null
  return v
}

function lines(text) {
  if (typeof text !== 'string') return null
  return text.replace(/\r\n/g, '\n').split('\n')
}

// ① queue/shogun_to_karo.yaml -> ids of cmds that are not finished
export function parseCommands(text) {
  const ls = lines(text)
  if (!ls) return { ok: false, reason: 'not-text' }
  let sawRoot = false
  let empty = false
  const entries = []
  for (const line of ls) {
    if (line.trim() === '' || /^\s*#/.test(line) || line === '---') continue
    if (/\t/.test(line.match(/^\s*/)[0])) return { ok: false, reason: 'tab-indent' }
    if (!sawRoot) {
      if (/^commands:\s*(#.*)?$/.test(line)) { sawRoot = true; continue }
      if (/^commands:\s*\[\s*\]\s*(#.*)?$/.test(line)) { sawRoot = true; empty = true; continue }
      return { ok: false, reason: 'no-commands-key' }
    }
    if (empty) return { ok: false, reason: 'entries-after-empty-list' }
    if (line[0] !== ' ') {
      const m = line.match(/^- id:\s*(.*)$/)
      if (!m) return { ok: false, reason: 'unexpected-top-level-line' }
      const id = scalar(m[1])
      if (id === null || !/^cmd_\w+$/.test(id)) return { ok: false, reason: 'bad-id' }
      entries.push({ id, status: undefined })
      continue
    }
    if (entries.length === 0) return { ok: false, reason: 'indented-before-first-entry' }
    const sm = line.match(/^ {2}status:\s*(.*)$/)
    if (sm) {
      const cur = entries[entries.length - 1]
      if (cur.status !== undefined) return { ok: false, reason: 'duplicate-status' }
      const s = scalar(sm[1])
      if (s === null) return { ok: false, reason: 'bad-status' }
      cur.status = s
    }
  }
  if (!sawRoot) return { ok: false, reason: 'no-commands-key' }
  if (!empty && entries.length === 0) return { ok: false, reason: 'no-entries' }
  const active = []
  for (const e of entries) {
    if (e.status === undefined) return { ok: false, reason: 'missing-status:' + e.id }
    if (CMD_TERMINAL.test(e.status)) continue
    if (CMD_ACTIVE.has(e.status)) { active.push(e.id); continue }
    return { ok: false, reason: 'unexpected-status:' + e.id }
  }
  return { ok: true, active }
}

// ② dashboard.md '## 🚨 要対応' -> number of items that are neither ✅ nor struck through
export function parseAlerts(text) {
  const ls = lines(text)
  if (!ls) return { ok: false, reason: 'not-text' }
  const start = ls.findIndex((l) => l.startsWith('## 🚨 要対応'))
  if (start < 0) return { ok: false, reason: 'no-heading' }
  let count = 0
  let inComment = false
  for (let i = start + 1; i < ls.length; i++) {
    const line = ls[i]
    if (/^## /.test(line)) break
    if (inComment) { if (line.includes('-->')) inComment = false; continue }
    if (line.trim() === '') continue
    if (/^\s*<!--/.test(line)) { if (!line.includes('-->')) inComment = true; continue }
    if (/^\s/.test(line)) continue // continuation of an item
    const m = line.match(/^(?:[-*]|\d+\.)\s+(.*)$/)
    if (m) {
      if (!(m[1].startsWith('✅') || m[1].startsWith('~~'))) count += 1
      continue
    }
    if (/^[（(]?\s*なし(\s|[）)]|$)/.test(line)) continue // explicit "none" placeholder
    return { ok: false, reason: 'unrecognized-line' }
  }
  return { ok: true, count }
}

// ③a queue/tasks/<name>.yaml -> one-character state
export function parseTaskState(text) {
  const ls = lines(text)
  if (!ls) return { ok: false, reason: 'not-text' }
  let inTask = false
  for (const line of ls) {
    if (/^task:\s*(#.*)?$/.test(line)) { inTask = true; continue }
    if (!inTask) continue
    if (line.trim() !== '' && line[0] !== ' ' && !/^\s*#/.test(line)) break
    const m = line.match(/^ {2}status:\s*(.*)$/)
    if (!m) continue
    const s = scalar(m[1])
    if (s === null) return { ok: false, reason: 'bad-status' }
    const state = TASK_STATE[s]
    return state ? { ok: true, status: s, state } : { ok: false, reason: 'unexpected-status' }
  }
  return { ok: false, reason: 'no-status' }
}

// ③b queue/inbox/<name>.yaml -> number of entries with read: false
export function parseUnread(text) {
  const ls = lines(text)
  if (!ls) return { ok: false, reason: 'not-text' }
  let sawRoot = false
  let empty = false
  let entries = 0
  let reads = 0
  let unread = 0
  for (const line of ls) {
    if (line.trim() === '' || /^\s*#/.test(line)) continue
    if (!sawRoot) {
      if (/^messages:\s*(#.*)?$/.test(line)) { sawRoot = true; continue }
      if (/^messages:\s*\[\s*\]\s*(#.*)?$/.test(line)) { sawRoot = true; empty = true; continue }
      return { ok: false, reason: 'no-messages-key' }
    }
    if (empty) return { ok: false, reason: 'entries-after-empty-list' }
    if (line[0] === '-') {
      entries += 1
      continue
    }
    if (line[0] !== ' ') return { ok: false, reason: 'unexpected-top-level-line' }
    const m = line.match(/^ {2}read:\s*(.*)$/)
    if (m) {
      const v = scalar(m[1])
      if (v !== 'true' && v !== 'false') return { ok: false, reason: 'bad-read' }
      reads += 1
      if (v === 'false') unread += 1
    }
  }
  if (!sawRoot) return { ok: false, reason: 'no-messages-key' }
  if (reads !== entries) return { ok: false, reason: 'read-count-mismatch' }
  return { ok: true, unread }
}

// The view the band is drawn from. Before the first successful read everything is '?'.
export function unknownView() {
  return {
    cmds: { ok: false },
    alerts: { ok: false },
    agents: AGENTS.map((a) => ({ label: a.label, state: { ok: false }, inbox: { ok: false } })),
  }
}

export function formatLine(v) {
  const MAX_IDS = 3
  let cmds = '進行cmd ?'
  if (v.cmds.ok) {
    const ids = v.cmds.active
    const shown = ids.slice(0, MAX_IDS).join(' ') + (ids.length > MAX_IDS ? ' …' : '')
    cmds = '進行cmd ' + ids.length + (ids.length > 0 ? ' [' + shown + ']' : '')
  }
  const alerts = '🚨' + (v.alerts.ok ? v.alerts.count : '?')
  const agents = v.agents
    .map((a) => a.label + (a.state.ok ? a.state.state : '?') + '/' + (a.inbox.ok ? a.inbox.unread : '?'))
    .join(' ')
  return [cmds, alerts, agents].join(' │ ')
}
