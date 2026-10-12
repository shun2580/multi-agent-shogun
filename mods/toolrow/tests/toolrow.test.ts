import { expect, test } from 'claude-code/testing'
import { MCP_NAME, MODE, NAMES } from '../hooks/config.js'
import { brief, handleToolUse, labelFor, outputLines, stateMark } from '../hooks/lib.js'

// ---- fixtures ------------------------------------------------------------------------------

// The table the Lord approved as the default (cmd227_tool_row_research.md §5). A rename edits config.js and this list.
const TABLE: Array<[string, string]> = [
  ['Bash', '陣触れ'],
  ['Read', '巻物拝見'],
  ['Edit', '書状訂正'],
  ['Write', '書状認め'],
  ['Grep', '物見'],
  ['Glob', '地図検分'],
  ['Agent', '伝令派遣'],
  ['WebFetch', '遠文取寄'],
  ['WebSearch', '諜報'],
  ['NotebookEdit', '帳面訂正'],
  ['TodoWrite', '軍議記帳'],
]
const MCP = 'mcp__claude_ai_Gmail__search_threads'

const ROW = (props: Record<string, unknown>) =>
  ({
    plugin: 'shogun-toolrow',
    component: 'ToolUse',
    requestId: 'toolu_1',
    surface: 'terminal',
    viewport: { columns: 120, rows: 40 },
    props: { tool_use_id: 'toolu_1', input: {}, isRunning: false, isErrored: false, isInterrupted: false, ...props },
  }) as any

// Loads the shipped Mod (plan A as shipped). The layer under it records the props it receives and draws a marker text.
// Every call that is not a render is recorded in `others`.
async function load($: any, on: any, under?: (e: any, $: any) => any) {
  const seen: any[] = []
  const others: string[] = []
  for (const ev of ['env.get', 'fs.read', 'fs.write', 'process.run', 'http.fetch', 'tool.check', 'tool.describe']) {
    on(ev, () => {
      others.push(ev)
      return { deny: 'not expected' }
    })
  }
  on('ui.render', { component: 'ToolUse' }, ($: any, e: any, next: any) => {
    seen.push(e.props)
    if (under) return under(e, $)
    return { type: 'Text', props: {}, children: ['under:' + e.props.tool] }
  })
  return { seen, others }
}

async function drawn($: any, props: Record<string, unknown>) {
  const ui = await $.ui.mount(ROW(props))
  const texts = (await ui.findAll({ type: 'Text' })).map((n: any) => String(n.children.join('')))
  await ui.unmount()
  return texts
}

// ---- the names (labelFor) ------------------------------------------------------------------

test('the table holds exactly the approved names, no more', async () => {
  expect(Object.entries(NAMES)).toEqual(TABLE)
  expect(MCP_NAME).toBe('遠国の技')
})

test('every name keeps the original tool name in brackets', async () => {
  for (const [tool, name] of TABLE) expect(labelFor(tool)).toBe(`${name}（${tool}）`)
  expect(labelFor(MCP)).toBe(`遠国の技（${MCP}）`)
  expect(labelFor('mcp__srv__a__b')).toBe('遠国の技（mcp__srv__a__b）')
})

test('a tool that is not on the list gets no name', async () => {
  const none = [
    'SomethingNew', 'Skill', 'TaskCreate', 'bash', 'BASH', 'Bash ', ' Bash', 'Bash\n', '', 'mcp__', 'mcp__x', 'mcp____', 'mcp_x__y',
    'toString', '__proto__', 'constructor', 'hasOwnProperty', 'valueOf',
  ]
  for (const t of none) expect(labelFor(t)).toBeNull()
  for (const v of [undefined, null, 3, true, {}, ['Bash']]) expect(labelFor(v as unknown as string)).toBeNull()
})

test('a name that is already shown is left alone (applying it twice changes nothing)', async () => {
  for (const [tool] of TABLE) expect(labelFor(labelFor(tool) as string)).toBeNull()
  expect(labelFor(labelFor(MCP) as string)).toBeNull()
})

test('the mod ships in plan A', async () => {
  expect(MODE).toBe('props')
})

// ---- plan A through Claude Code's events (the shipped Mod) ---------------------------------

test('plan A: the layer under receives the shown name; every other prop arrives as it was', async ($, on) => {
  const w = await load($, on)
  const input = { command: 'ls -la', description: 'list' }
  const output = { stdout: 'a', stderr: '' }
  for (const [tool, name] of TABLE) {
    const props = { tool, input, isRunning: false, isErrored: true, isInterrupted: false, output, onScreen: null }
    const texts = await drawn($, props)
    expect(texts).toEqual([`under:${name}（${tool}）`])
    const got = w.seen[w.seen.length - 1]
    expect(got).toEqual({ ...ROW(props).props, tool: `${name}（${tool}）` })
  }
})

test('plan A: an MCP tool is shown with its whole original name', async ($, on) => {
  const w = await load($, on)
  expect(await drawn($, { tool: MCP })).toEqual([`under:遠国の技（${MCP}）`])
  expect(w.seen[0].tool).toBe(`遠国の技（${MCP}）`)
})

test('plan A: a tool not on the list reaches the layer under exactly as it came', async ($, on) => {
  const w = await load($, on)
  for (const tool of ['SomethingNew', 'Skill', 'mcp__', 'toString', '']) {
    const props = { tool, input: { x: 1 }, isRunning: true, isErrored: false, isInterrupted: false }
    expect(await drawn($, props)).toEqual([`under:${tool}`])
    expect(w.seen[w.seen.length - 1]).toEqual(ROW(props).props)
  }
})

test('plan A: running, errored and interrupted rows still carry their state to the layer under', async ($, on) => {
  const w = await load($, on)
  await drawn($, { tool: 'Bash', isRunning: true })
  await drawn($, { tool: 'Bash', isErrored: true, output: 'boom' })
  await drawn($, { tool: 'Bash', isInterrupted: true, output: 'cut' })
  expect(w.seen.map((p: any) => [p.isRunning, p.isErrored, p.isInterrupted])).toEqual([
    [true, false, false],
    [false, true, false],
    [false, false, true],
  ])
  expect(w.seen[1].output).toBe('boom')
  expect(w.seen[2].output).toBe('cut')
})

// ---- observe only --------------------------------------------------------------------------

test('drawing is a table lookup: no environment, file, process or network access, and the tool.* events are not hooked', async ($, on) => {
  const w = await load($, on)
  for (let i = 0; i < 5; i++) await drawn($, { tool: 'Read', input: { file_path: '/a/b.ts' } })
  expect(w.others).toEqual([])
})

test('tool calls, checks and descriptions pass through the Mod unchanged', async ($, on) => {
  on('tool.call', ($: any, e: any) => ({ result: 'claude code ran ' + e.tool }))
  await load($, on)
  const r = await $.tool.call({ tool: 'Bash', command: 'rm -rf /' })
  expect(r).toEqual({ result: 'claude code ran Bash' })
})

test('other render sites are not touched by the Mod', async ($, on) => {
  await load($, on)
  on('ui.render', ($: any, e: any) => ({ type: 'Text', props: {}, children: ['site:' + e.component] }))
  const ui = await $.ui.mount({
    plugin: 'shogun-toolrow',
    component: 'AbovePrompt',
    requestId: 'band',
    surface: 'terminal',
    viewport: { columns: 120, rows: 40 },
    props: { hasSurvey: false, isWorking: false, maxRows: 3, bodyColumns: 118, scroll: { offset: 0, bodyRows: 3 }, view: {} },
  })
  expect(await ui.find({ type: 'Text', text: /site:AbovePrompt/ })).toBeDefined()
  await ui.unmount()
})

// ---- plan B: the Mod's own row (handleToolUse in 'tree' mode, through the kit's validation) ----

// The shipped hook is plan A. To run plan B through the engine, the layer under it draws the row with the very
// same code (`handleToolUse('tree', ...)`), given the original tool name back.
async function loadTree($: any, on: any) {
  const nexts: any[] = []
  const others: string[] = []
  for (const ev of ['env.get', 'fs.read', 'fs.write', 'process.run', 'http.fetch']) {
    on(ev, () => {
      others.push(ev)
      return { deny: 'not expected' }
    })
  }
  on('ui.render', { component: 'ToolUse' }, ($: any, e: any) => {
    const original = e.props.tool.replace(/^.*（(.*)）$/, '$1')
    const entry = { ...e, props: { ...e.props, tool: original } }
    return handleToolUse('tree', () => $.ui.resolve(entry), entry, (x: any) => {
      nexts.push(x)
      return { type: 'Text', props: {}, children: ['engine row:' + x.props.tool] }
    })
  })
  return { nexts, others }
}

test('plan B: a finished call is one row: mark, shown name in bold, argument in brackets', async ($, on) => {
  await loadTree($, on)
  const ui = await $.ui.mount(ROW({ tool: 'Bash', input: { command: 'ls -la' } }))
  expect((await ui.findAll({ type: 'Text' })).map((n: any) => String(n.children.join('')))).toEqual(['● ', '陣触れ（Bash）', '(ls -la)'])
  const name = await ui.find({ type: 'Text', text: /陣触れ/ })
  expect(name).toBeDefined()
  await ui.unmount()
})

test('plan B: each state has its own mark', async ($, on) => {
  await loadTree($, on)
  const marks: string[] = []
  for (const p of [{ isRunning: true }, {}, { isErrored: true }, { isInterrupted: true }]) {
    const t = await drawn($, { tool: 'Read', input: { file_path: '/a/b.ts' }, ...p })
    marks.push(t[0])
  }
  expect(marks).toEqual(['… ', '● ', '✗ ', '⊘ '])
  expect(new Set(marks).size).toBe(4)
})

test('plan B: an interrupted call says so and shows the first lines of what was read', async ($, on) => {
  await loadTree($, on)
  const t = await drawn($, { tool: 'Bash', input: { command: 'sleep 9' }, isInterrupted: true, output: 'a\n\nb\nc\nd\ne' })
  expect(t).toEqual(['⊘ ', '陣触れ（Bash）', '(sleep 9)', ' Interrupted', '  a', '  b', '  c'])
})

test('plan B: an errored call shows its result text; a successful one adds nothing under the row', async ($, on) => {
  await loadTree($, on)
  const bad = await drawn($, { tool: 'Bash', input: { command: 'false' }, isErrored: true, output: { stdout: '', stderr: 'exit 1' } })
  expect(bad).toEqual(['✗ ', '陣触れ（Bash）', '(false)', '  exit 1'])
  const ok = await drawn($, { tool: 'Bash', input: { command: 'true' }, output: { stdout: 'lots\nof\nlines', stderr: '' } })
  expect(ok).toEqual(['● ', '陣触れ（Bash）', '(true)'])
})

test('plan B: a tool not on the list is the engine row, untouched', async ($, on) => {
  const w = await loadTree($, on)
  const t = await drawn($, { tool: 'SomethingNew', input: { x: 1 } })
  expect(t).toEqual(['engine row:SomethingNew'])
  expect(w.nexts.length).toBe(1)
})

test('plan B: an MCP tool is drawn with its whole original name', async ($, on) => {
  await loadTree($, on)
  const t = await drawn($, { tool: MCP, input: { query: 'x' } })
  expect(t).toEqual(['● ', `遠国の技（${MCP}）`])
})

test('plan B: an input of an unknown shape does not stop the row', async ($, on) => {
  await loadTree($, on)
  for (const input of [undefined, null, 3, 'str', [], [1, 2], { command: 42 }, { command: { a: 1 } }, {}]) {
    const t = await drawn($, { tool: 'Bash', input })
    expect(t.slice(0, 2)).toEqual(['● ', '陣触れ（Bash）'])
    expect(t.length).toBe(2)
  }
})

test('plan B: drawing reads memory only', async ($, on) => {
  const w = await loadTree($, on)
  for (let i = 0; i < 5; i++) await drawn($, { tool: 'Grep', input: { pattern: 'x' } })
  expect(w.others).toEqual([])
})

// ---- the switch and its safety nets (handleToolUse, plain values) --------------------------

const fakeResolve = () => ({
  Box: (p: any) => ({ type: 'Box', props: { flexDirection: p.flexDirection }, children: p.children }),
  Text: (p: any) => ({ type: 'Text', children: p.children }),
})
const flat = (n: any): string => (typeof n === 'string' ? n : (n.children || []).map(flat).join(''))

test('switch: mode "props" rewrites only the tool; mode "tree" draws and does not call next', async () => {
  const e = { component: 'ToolUse', props: { tool: 'Bash', input: { command: 'ls' }, isRunning: false, isErrored: false, isInterrupted: false } }
  const calls: any[] = []
  const next = async (x: any) => {
    calls.push(x)
    return 'engine'
  }
  expect(await handleToolUse('props', fakeResolve, e, next)).toBe('engine')
  expect(calls[0]).toEqual({ ...e, props: { ...e.props, tool: '陣触れ（Bash）' } })
  expect(e.props.tool).toBe('Bash') // the input event is not mutated
  calls.length = 0
  const node: any = await handleToolUse('tree', fakeResolve, e, next)
  expect(calls.length).toBe(0)
  expect(flat(node)).toBe('● 陣触れ（Bash）(ls)')
})

test('switch: any other mode is plan A', async () => {
  const e = { props: { tool: 'Read', input: {} } }
  for (const mode of [undefined, null, '', 'Tree', 'TREE', 'treee', 'a', 'props', 3]) {
    const got = await handleToolUse(mode as any, fakeResolve, e, async (x: any) => x)
    expect((got as any).props.tool).toBe('巻物拝見（Read）')
  }
})

test('switch: a tool not on the list is next(e) with the very same object, in both plans', async () => {
  const e = { props: { tool: 'Skill', input: {} } }
  for (const mode of ['props', 'tree']) {
    const got = await handleToolUse(mode, fakeResolve, e, async (x: any) => x)
    expect(got).toBe(e)
  }
})

test('switch: plan B falls back to the engine row when drawing throws', async () => {
  const e = { props: { tool: 'Bash', input: { command: 'ls' } } }
  const boom = () => {
    throw new Error('resolve failed')
  }
  const got = await handleToolUse('tree', boom, e, async (x: any) => x)
  expect(got).toBe(e)
})

test('switch: a malformed event does not throw', async () => {
  for (const e of [undefined, null, {}, { props: null }, { props: {} }, { props: { tool: 5 } }]) {
    for (const mode of ['props', 'tree']) {
      const got = await handleToolUse(mode, fakeResolve, e as any, async (x: any) => x)
      expect(got).toBe(e)
    }
  }
})

// ---- the small pieces ----------------------------------------------------------------------

test('brief: one tool kind, one argument, short; unknown shapes give nothing', async () => {
  expect(brief('Bash', { command: 'ls -la\n  /tmp' })).toBe('ls -la /tmp')
  expect(Array.from(brief('Bash', { command: 'x'.repeat(500) })).length).toBe(80)
  expect(brief('Read', { file_path: '/a/b.ts' })).toBe('/a/b.ts')
  const long = '/very/long/' + 'dir/'.repeat(40) + 'file.ts'
  expect(brief('Edit', { file_path: long }).startsWith('…')).toBe(true)
  expect(brief('Edit', { file_path: long }).endsWith('file.ts')).toBe(true)
  expect(brief('Grep', { pattern: 'foo.*bar' })).toBe('foo.*bar')
  expect(brief('Agent', { description: 'do a thing' })).toBe('do a thing')
  expect(brief('WebFetch', { url: 'https://example.com' })).toBe('https://example.com')
  expect(brief('WebSearch', { query: 'q' })).toBe('q')
  expect(brief('NotebookEdit', { notebook_path: '/n.ipynb' })).toBe('/n.ipynb')
  expect(brief('TodoWrite', { todos: [1, 2, 3] })).toBe('3件')
  expect(brief(MCP, { query: 'x' })).toBe('')
  for (const bad of [undefined, null, 1, 'x', true, [], { command: 1 }, { todos: 'x' }]) {
    expect(brief('Bash', bad)).toBe('')
    expect(brief('TodoWrite', bad)).toBe('')
  }
  const trap = new Proxy({}, { get: () => { throw new Error('getter') } })
  expect(brief('Bash', trap)).toBe('')
})

test('outputLines: at most three short lines; unknown shapes give none', async () => {
  expect(outputLines('a\nb\nc\nd')).toEqual(['a', 'b', 'c'])
  expect(outputLines({ stdout: 'o', stderr: 'e' })).toEqual(['o', 'e'])
  expect(Array.from(outputLines('x'.repeat(1000))[0]).length).toBe(120)
  for (const bad of [undefined, null, 3, true, [], {}, { stdout: 1 }]) expect(outputLines(bad)).toEqual([])
})

test('stateMark: interrupted over errored over running', async () => {
  expect(stateMark({ isInterrupted: true, isErrored: true, isRunning: true })).toBe('⊘ ')
  expect(stateMark({ isErrored: true, isRunning: true })).toBe('✗ ')
  expect(stateMark({ isRunning: true })).toBe('… ')
  expect(stateMark({})).toBe('● ')
})
