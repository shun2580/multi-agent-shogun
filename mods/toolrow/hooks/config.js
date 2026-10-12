// shogun-toolrow: the two things the Lord may want to change, in one place.
// Plain data only. Nothing here runs at draw time except a table lookup.

// ---- 1. How the row is changed (journal S-17) ----------------------------------------------
//   'props' = plan A (default): hand the engine's own row a different `tool` string and keep its
//             argument summary, colours and layout. Whether the engine honours that is only
//             known on a real run.
//   'tree'  = plan B: draw the whole one-line row ourselves. Certain to show the new name, but the
//             argument summary and look are ours (simpler than the engine's).
// If plan A shows the original name on a real run, change this one word to 'tree' and restart.
// Any other value is treated as 'props'.
export const MODE = 'props'

// ---- 2. The names (cmd227_tool_row_research.md §5) ----------------------------------------
// The original tool name is always shown in full-width brackets after the name, so the tool is
// never in doubt. A tool that is not in this table is left alone and shown as the engine shows it:
// no name is ever guessed. To rename, edit the left-hand text only.
export const NAMES = {
  Bash: '陣触れ',
  Read: '巻物拝見',
  Edit: '書状訂正',
  Write: '書状認め',
  Grep: '物見',
  Glob: '地図検分',
  Agent: '伝令派遣',
  WebFetch: '遠文取寄',
  WebSearch: '諜報',
  NotebookEdit: '帳面訂正',
  TodoWrite: '軍議記帳',
}

// Any tool named mcp__<server>__<tool>. The whole original name is kept in the brackets.
export const MCP_NAME = '遠国の技'
