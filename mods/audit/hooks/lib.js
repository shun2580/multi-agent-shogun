// shogun-audit: pure record building. No I/O here, so every function is testable on plain values.
//
// What may be recorded (cmd_224): time, event kind, tool name, success, and - for the file tools only - the file path.
// Nothing else is ever copied from an event. Each record is built field by field from an allow-list below;
// the event object is never spread, so a new field on an event cannot leak into the log.

// The only names a log file may be named after. A value outside this list never reaches a path.
export const AGENTS = ['shogun', 'karo', 'gunshi', 'ashigaru1', 'ashigaru2', 'ashigaru3', 'ashigaru4', 'ashigaru5', 'ashigaru6', 'ashigaru7']

// Where records go when the name is missing or not on the list. Never another agent's file.
export const UNKNOWN_FILE = '_unknown'
export const UNKNOWN_MARK = '?'

// Tools whose target is a file: their path (and only their path) is recorded.
// NotebookEdit calls it notebook_path; it is recorded as file_path, the one key a reader greps for.
const FILE_TOOLS = { Read: 'file_path', Edit: 'file_path', Write: 'file_path', MultiEdit: 'file_path', NotebookEdit: 'notebook_path' }

// Where the secret values live. A path under it is recorded (an attempt to open it is exactly what an audit is for)
// but flagged, so the Lord can grep for it. The path is not a secret; the values inside are.
const SECRET_DIR = '/.config/multi-agent-shogun/'

const MAX_PATH = 1024
const MAX_TOOL = 128

// Exact match against the list. A value such as '../x', 'ashigaru1 ', 'ASHIGARU1' or a non-string is not a name.
export function resolveAgent(value) {
  return typeof value === 'string' && AGENTS.includes(value) ? value : null
}

const pad = (n, w = 2) => String(n).padStart(w, '0')

// Local time with offset (the queue files are local time too), e.g. 2026-10-12T10:30:00.123+09:00
export function localIso(d) {
  const off = -d.getTimezoneOffset()
  const sign = off < 0 ? '-' : '+'
  const abs = Math.abs(off)
  return (
    pad(d.getFullYear(), 4) + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
    'T' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds()) + '.' + pad(d.getMilliseconds(), 3) +
    sign + pad(Math.floor(abs / 60)) + ':' + pad(abs % 60)
  )
}

// The month directory comes from the event time (local), never from a clock read later.
export function monthOf(d) {
  return pad(d.getFullYear(), 4) + '-' + pad(d.getMonth() + 1)
}

// Absolute directory and file for one record.
export function targetFor(root, d, agent) {
  const dir = root + '/logs/audit/' + monthOf(d)
  return { dir, file: dir + '/' + (agent === null ? UNKNOWN_FILE : agent) + '.jsonl' }
}

function safeName(tool) {
  return typeof tool === 'string' && /^[A-Za-z0-9_.:-]+$/.test(tool) ? tool.slice(0, MAX_TOOL) : '?'
}

// The path of a file tool, or undefined. Never anything else of the call (content, old/new strings, ranges).
export function filePathOf(tool, e) {
  const key = Object.prototype.hasOwnProperty.call(FILE_TOOLS, tool) ? FILE_TOOLS[tool] : null
  if (key === null || e === null || typeof e !== 'object') return undefined
  const p = e[key]
  return typeof p === 'string' && p !== '' ? p.slice(0, MAX_PATH) : undefined
}

export function isSecretPath(p) {
  return typeof p === 'string' && p.includes(SECRET_DIR)
}

// What happened to a tool call, from the result next(e) gave back. Only the three flags are read, never the text.
export function outcomeOf(result) {
  if (result === null || typeof result !== 'object') return { ok: false, outcome: 'unknown' }
  if (typeof result.deny === 'string') return { ok: false, outcome: 'denied' }
  if (result.isError === true) return { ok: false, outcome: 'error' }
  return { ok: true }
}

function base(d, agent, kind, e) {
  const rec = { ts: localIso(d), agent: agent === null ? UNKNOWN_MARK : agent, event: kind }
  // A subagent's call carries agentId. The id itself is not recorded, only that it was a subagent.
  if (e && typeof e === 'object' && e.agentId !== undefined && e.agentId !== null) rec.sub = true
  return rec
}

// One tool call, after it finished. `done` is outcomeOf(result), or { ok: false, outcome: 'threw' }.
export function toolRecord(d, agent, e, done) {
  const tool = safeName(e && e.tool)
  const rec = base(d, agent, 'tool.call', e)
  rec.tool = tool
  rec.ok = done.ok
  if (done.outcome !== undefined) rec.outcome = done.outcome
  const p = filePathOf(tool, e)
  if (p !== undefined) {
    rec.file_path = p
    if (isSecretPath(p)) rec.sensitive = true
  }
  return rec
}

// turn.start: the prompt text is not recorded. turnId only ties start to complete.
export function turnStartRecord(d, agent, e) {
  const rec = base(d, agent, 'turn.start', e)
  if (e && typeof e.turnId === 'string') rec.turn = e.turnId.slice(0, 64)
  return rec
}

// turn.complete: the answer text is not recorded.
export function turnCompleteRecord(d, agent, e) {
  const rec = base(d, agent, 'turn.complete', e)
  if (e && typeof e.turnId === 'string') rec.turn = e.turnId.slice(0, 64)
  if (e && typeof e.reason === 'string') rec.reason = e.reason.slice(0, 32)
  if (e && typeof e.durationMs === 'number') rec.ms = Math.round(e.durationMs)
  if (e && typeof e.isAborted === 'boolean') rec.aborted = e.isAborted
  return rec
}

// One line of JSONL.
export function toLine(rec) {
  return JSON.stringify(rec) + '\n'
}
