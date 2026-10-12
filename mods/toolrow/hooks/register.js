// shogun-toolrow: display-only tool row.
// Draws a tool call's heading row as "<warrior name>（<original tool name>）", e.g. 陣触れ（Bash）.
//
// The only thing registered is ui.render for the ToolUse row. tool.call, tool.check and tool.describe are
// not registered, so a call, its arguments, its result and what the model reads are never touched.
// Spinner, spinnerVerbs and ToolGroup (the folded "Read 3 files…" line) are not touched either.
// Drawing does a table lookup and string work only: no environment, file, process or network access.
//
// The names and the plan A / plan B switch are in config.js.
import { MODE } from './config.js'
import { handleToolUse } from './lib.js'

export function register(on) {
  on('ui.render', { component: 'ToolUse' }, async ($, e, next) => handleToolUse(MODE, () => $.ui.resolve(e), e, next))
}
