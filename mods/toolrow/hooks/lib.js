// shogun-toolrow: pure naming, summarising and drawing helpers. No I/O here: every function works on
// plain values, so it is safe to run on every redraw and testable without the engine.
import { NAMES, MCP_NAME } from './config.js'

const has = (obj, key) => Object.prototype.hasOwnProperty.call(obj, key)

// mcp__<server>__<tool>. The server name may itself contain underscores.
const MCP_RE = /^mcp__.+__.+$/

// The row text for a tool: "<name>（<original tool name>）", or null when the tool is not on the list.
// null means "leave the row alone". A name outside the table is never guessed; 'toString', '__proto__'
// and non-strings are not on the list. A row that already carries a shown name is not on the list either,
// so applying this twice changes nothing.
export function labelFor(tool) {
  if (typeof tool !== 'string' || tool === '') return null
  if (has(NAMES, tool)) {
    const name = NAMES[tool]
    return typeof name === 'string' && name !== '' ? name + '（' + tool + '）' : null
  }
  if (MCP_RE.test(tool)) return MCP_NAME + '（' + tool + '）'
  return null
}

// ---- plan B only: the pieces of a row we draw ourselves --------------------------------------

const MAX_BRIEF = 80
const MAX_OUTPUT_LINES = 3
const MAX_OUTPUT_COLUMNS = 120

function oneLine(s, max) {
  const t = String(s).replace(/\s+/g, ' ').trim()
  const chars = Array.from(t)
  return chars.length > max ? chars.slice(0, max - 1).join('') + '…' : t
}

// A long path keeps its tail, which is the part that tells files apart.
function pathTail(s, max) {
  const t = String(s).trim()
  const chars = Array.from(t)
  return chars.length > max ? '…' + chars.slice(chars.length - (max - 1)).join('') : t
}

// What goes in the brackets after the name, like the engine's `Bash(ls -la)`. Kept short on purpose:
// the argument of one tool kind, or nothing. An input of an unknown shape gives '' and never throws.
export function brief(tool, input) {
  try {
    if (input === null || typeof input !== 'object') return ''
    const str = (k) => (typeof input[k] === 'string' ? input[k] : '')
    switch (tool) {
      case 'Bash':
        return oneLine(str('command'), MAX_BRIEF)
      case 'Read':
      case 'Edit':
      case 'Write':
        return pathTail(str('file_path'), MAX_BRIEF)
      case 'NotebookEdit':
        return pathTail(str('notebook_path'), MAX_BRIEF)
      case 'Grep':
      case 'Glob':
        return oneLine(str('pattern'), MAX_BRIEF)
      case 'Agent':
        return oneLine(str('description'), MAX_BRIEF)
      case 'WebFetch':
        return oneLine(str('url'), MAX_BRIEF)
      case 'WebSearch':
        return oneLine(str('query'), MAX_BRIEF)
      case 'TodoWrite':
        return Array.isArray(input.todos) ? input.todos.length + '件' : ''
      default:
        return ''
    }
  } catch (err) {
    return ''
  }
}

// The first lines of a result text, for a row that failed or was cut. A result of an unknown shape gives [].
export function outputLines(output) {
  try {
    let text = ''
    if (typeof output === 'string') text = output
    else if (output !== null && typeof output === 'object') {
      const parts = []
      if (typeof output.stdout === 'string' && output.stdout) parts.push(output.stdout)
      if (typeof output.stderr === 'string' && output.stderr) parts.push(output.stderr)
      text = parts.join('\n')
    }
    return text
      .split('\n')
      .map((l) => l.trimEnd())
      .filter((l) => l !== '')
      .slice(0, MAX_OUTPUT_LINES)
      .map((l) => oneLine(l, MAX_OUTPUT_COLUMNS))
  } catch (err) {
    return []
  }
}

// One mark for each state of a row. Interrupted wins over errored, errored over running.
export function stateMark(p) {
  if (p.isInterrupted === true) return '⊘ '
  if (p.isErrored === true) return '✗ '
  if (p.isRunning === true) return '… '
  return '● '
}

// Plan B: the whole row, drawn here. `shown` is the row text from labelFor.
// Only when the call failed or was cut are the first lines of its result drawn under the row, because for
// those the row says nothing else; a successful result is the engine's own result block (or its group).
export function treeRow({ Box, Text }, p, shown) {
  const parts = [Text({ children: [stateMark(p)] }), Text({ bold: true, children: [shown] })]
  const b = brief(p.tool, p.input)
  if (b) parts.push(Text({ wrap: 'truncate', children: ['(' + b + ')'] }))
  if (p.isInterrupted === true) parts.push(Text({ dimColor: true, children: [' Interrupted'] }))
  const row = Box({ flexDirection: 'row', children: parts })
  const lines = p.isErrored === true || p.isInterrupted === true ? outputLines(p.output) : []
  if (lines.length === 0) return row
  return Box({
    flexDirection: 'column',
    children: [row, ...lines.map((l) => Text({ dimColor: true, wrap: 'truncate', children: ['  ' + l] }))],
  })
}

// What the ui.render hook for the ToolUse row does. `mode` is 'props' (plan A) or 'tree' (plan B); anything
// else is 'props'. `resolve` returns the engine's { Box, Text } for this row (only plan B calls it).
//   - a tool that is not on the list: next(e), untouched. The row is the engine's.
//   - plan A: next() with only `tool` changed.
//   - plan B: our own row; if drawing it throws, next(e).
// Nothing is read from the environment, a file or the network here.
export async function handleToolUse(mode, resolve, e, next) {
  const shown = labelFor(e && e.props ? e.props.tool : undefined)
  if (shown === null) return next(e)
  if (mode !== 'tree') return next({ ...e, props: { ...e.props, tool: shown } })
  try {
    return treeRow(resolve(), e.props, shown)
  } catch (err) {
    return next(e)
  }
}
