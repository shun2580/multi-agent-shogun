import { expect, mock, test } from 'claude-code/testing'
import { AGENTS, formatLine, parseAlerts, parseCommands, parseTaskState, parseUnread, unknownView } from '../hooks/lib.js'

// ---- fixtures: the shapes the real files have ----------------------------------------------

const CMDS_ACTIVE = `commands:
- id: cmd_001
  timestamp: '2026-01-01T00:00:00Z'
  north_star: |
    multi-line
    status: not-a-real-key
  status: done
- id: cmd_002
  status: in_progress
- id: cmd_003
  status: superseded_by_cmd_075
- id: cmd_004
  status: done_with_caveat   # trailing comment
- id: cmd_005
  status: cancelled_by_lord
- id: cmd_006
  status: failed_gate
- id: cmd_007
  status: pending
`

const DASH = `# dashboard
## 🛡️ Watcher
- something
## 🚨 要対応
<!-- created_at: 2026-10-08 -->
- ✅**resolved**: continued
  continuation line, not an item
- ~~struck~~
- open item one
- **open item two**
1. numbered open item

## 🙅 対応しない
- not counted
`

const task = (s: string) => `task:\n  task_id: x\n  status: ${s}\n  description: |\n    status: ignored\n`
const inbox = (...reads: string[]) =>
  'messages:\n' + reads.map((r, i) => `- id: m${i}\n  content: 'a\n    folded'\n  read: ${r}\n`).join('')

// ---- ① cmds ---------------------------------------------------------------------------------

test('cmds: counts only cmds that are not finished', async () => {
  expect(parseCommands(CMDS_ACTIVE)).toEqual({ ok: true, active: ['cmd_002', 'cmd_007'] })
  expect(parseCommands('commands: []\n')).toEqual({ ok: true, active: [] })
})

test('cmds: every unreadable shape is ?, never 0', async () => {
  const bad = [
    '', // empty file
    'tasks:\n- id: cmd_1\n  status: done\n', // wrong root key
    'commands:\n', // no entries and not an explicit empty list
    'commands:\n- id: cmd_1\n', // entry without status
    'commands:\n- id: cmd_1\n  status: weird_value\n', // unexpected status
    'commands:\n- id: cmd_1\n  status: done\n  status: done\n', // duplicate status
    'commands:\n- id: nope\n  status: done\n', // id is not cmd_*
    'commands:\n- id: cmd_1\n  status: |\n    done\n', // block scalar status
    'commands:\n\t- id: cmd_1\n  status: done\n', // tab indentation
    'commands: []\n- id: cmd_1\n  status: in_progress\n', // entries after an empty list
    'commands:\n  - id: cmd_1\n    status: in_progress\n', // indented list: not the shape we read
  ]
  for (const text of bad) expect(parseCommands(text).ok).toBe(false)
  expect(parseCommands(undefined as unknown as string).ok).toBe(false)
  expect(formatLine({ ...unknownView(), cmds: parseCommands('') })).toMatch(/^進行cmd \? /)
})

// ---- ② alerts -------------------------------------------------------------------------------

test('alerts: counts items under the 🚨 heading that are neither ✅ nor struck through', async () => {
  expect(parseAlerts(DASH)).toEqual({ ok: true, count: 3 })
  expect(parseAlerts('## 🚨 要対応\n（なし）\n## next\n')).toEqual({ ok: true, count: 0 })
  expect(parseAlerts('## 🚨 要対応 - 殿のご判断\nなし\n')).toEqual({ ok: true, count: 0 })
  expect(parseAlerts('## 🚨 要対応\nなし (None)\n')).toEqual({ ok: true, count: 0 })
  expect(parseAlerts('## 🚨 要対応\n- ✅ done\n')).toEqual({ ok: true, count: 0 })
})

test('alerts: no heading or an unrecognised line is ?, never 0', async () => {
  expect(parseAlerts('# dashboard\n## other\n- x\n').ok).toBe(false)
  expect(parseAlerts('').ok).toBe(false)
  expect(parseAlerts('## 🚨 要対応\nsome free paragraph\n').ok).toBe(false)
  expect(parseAlerts('## 🚨 要対応\n| a | b |\n').ok).toBe(false)
  expect(formatLine({ ...unknownView(), alerts: parseAlerts('') })).toContain('🚨?')
})

// ---- ③ agents -------------------------------------------------------------------------------

test('task state: done and completed both read as finished', async () => {
  expect(parseTaskState(task('done'))).toEqual({ ok: true, status: 'done', state: '済' })
  expect(parseTaskState(task('completed'))).toEqual({ ok: true, status: 'completed', state: '済' })
  expect(parseTaskState(task('assigned  # note')).state).toBe('稼')
  expect(parseTaskState(task('idle')).state).toBe('休')
})

test('task state: unreadable shapes are ?', async () => {
  expect(parseTaskState('').ok).toBe(false)
  expect(parseTaskState('other:\n  status: done\n').ok).toBe(false)
  expect(parseTaskState('task:\n  task_id: x\n').ok).toBe(false)
  expect(parseTaskState(task('martian')).ok).toBe(false)
  expect(parseTaskState('task:\n  status: |\n    done\n').ok).toBe(false)
})

test('inbox: counts read: false, tolerates folded content', async () => {
  expect(parseUnread(inbox('true', 'false', 'false'))).toEqual({ ok: true, unread: 2 })
  expect(parseUnread('messages: []\n')).toEqual({ ok: true, unread: 0 })
})

test('inbox: unreadable shapes are ?', async () => {
  expect(parseUnread('').ok).toBe(false)
  expect(parseUnread('items:\n- read: false\n').ok).toBe(false)
  expect(parseUnread(inbox('maybe')).ok).toBe(false)
  expect(parseUnread('messages:\n- id: a\n  read: true\n- id: b\n').ok).toBe(false) // entry without read
})

// ---- the whole mod, through Claude Code's events -------------------------------------------

const ROOT = '/dummy/root'
const AB = {
  plugin: 'shogun-status',
  component: 'AbovePrompt',
  requestId: 'band',
  viewport: { columns: 188, rows: 50 },
  props: { hasSurvey: false, isWorking: false, maxRows: 3, bodyColumns: 186, scroll: { offset: 0, bodyRows: 3 }, view: {} },
} as const

type Files = Record<string, string | undefined>

// Loads the mod against an in-memory queue. A file whose value is undefined is missing.
async function load($: any, on: any, files: Files) {
  const reads: string[] = []
  const writes: string[] = []
  mock.clock(on)
  on('env.get', () => ({ value: ROOT }))
  on('fs.read', ($: any, e: any) => {
    reads.push(e.path)
    const text = files[e.path.slice(ROOT.length + 1)]
    return text === undefined ? { deny: 'ENOENT' } : { value: text }
  })
  on('fs.write', ($: any, e: any) => {
    writes.push(e.path)
    return { value: undefined }
  })
  on('session.start', () => ({ cwd: '/work' }))
  on('ui.render', () => ({ type: 'Text', props: {}, children: ['drawn by Claude Code'] }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  const ui = await $.ui.mount({ ...AB, surface: 'terminal' })
  const band = await ui.find({ type: 'Text', text: /進行cmd/ })
  await ui.unmount()
  return { reads, writes, text: band ? String(band.children.join('')) : undefined }
}

const FULL: Files = {
  'queue/shogun_to_karo.yaml': CMDS_ACTIVE,
  'dashboard.md': DASH,
  ...Object.fromEntries(AGENTS.flatMap((a) => [[`queue/tasks/${a.name}.yaml`, task('done')], [`queue/inbox/${a.name}.yaml`, inbox('true')]])),
}

test('the band shows cmds, alerts and every agent from the files', async ($, on) => {
  const files = { ...FULL, 'queue/tasks/ashigaru2.yaml': task('assigned'), 'queue/inbox/karo.yaml': inbox('false', 'false') }
  const r = await load($, on, files)
  expect(r.text).toContain('進行cmd 2 [cmd_002 cmd_007]')
  expect(r.text).toContain('🚨3')
  expect(r.text).toContain('将/0 家/2 軍済/0')
  expect(r.text).toContain('足2稼/0')
  expect(r.text).not.toContain('?')
})

test('only the ten named agents are read: test_* in queue/ is never counted', async ($, on) => {
  const files = { ...FULL, 'queue/inbox/test_timing_068.yaml': inbox('false'), 'queue/tasks/test_x.yaml': task('assigned') }
  const r = await load($, on, files)
  expect(r.reads.some((p) => p.includes('test_'))).toBe(false)
  // cmd_221: shogun and karo read their inbox only, the other eight read inbox + task.
  // 2 (cmds, dashboard) + 2 (shogun/karo inbox) + 8 x 2 = 20 (was 2 + 10 x 2 = 22 before cmd_221).
  expect(r.reads.length).toBe(2 + 2 + (AGENTS.length - 2) * 2)
})

test('a missing file shows ? for that item only', async ($, on) => {
  const files: Files = { ...FULL, 'queue/tasks/ashigaru1.yaml': undefined, 'dashboard.md': undefined }
  delete files['queue/tasks/ashigaru1.yaml']
  delete files['dashboard.md']
  const r = await load($, on, files)
  expect(r.text).toContain('🚨?')
  expect(r.text).toContain('足1?/0')
  expect(r.text).toContain('進行cmd 2')
})

// ---- cmd_221: shogun and karo show the unread count only -----------------------------------

// load() sets up the mock clock and hooks, so it can run once per test.
const SK_FILES = (): Files => {
  const files: Files = { ...FULL, 'queue/inbox/shogun.yaml': inbox('false'), 'queue/inbox/karo.yaml': inbox('false', 'true', 'false') }
  for (const name of ['shogun', 'karo']) delete files[`queue/tasks/${name}.yaml`]
  return files
}

test('shogun and karo: unread count only, no state and no ?, when there is no task file', async ($, on) => {
  const r = await load($, on, SK_FILES())
  expect(r.text).toContain('将/1 家/2 軍済/0')
  expect(r.text).not.toContain('?')
})

test('shogun and karo: a task file that exists is neither read nor shown', async ($, on) => {
  const r = await load($, on, { ...SK_FILES(), 'queue/tasks/shogun.yaml': task('assigned'), 'queue/tasks/karo.yaml': task('blocked') })
  expect(r.text).toContain('将/1 家/2 軍済/0')
  expect(r.text).not.toContain('?')
  expect(r.reads.some((p) => p.endsWith('/queue/tasks/shogun.yaml') || p.endsWith('/queue/tasks/karo.yaml'))).toBe(false)
  expect(r.reads.filter((p) => p.includes('/queue/tasks/')).length).toBe(AGENTS.length - 2)
})

test('shogun and karo: a missing inbox file is ?, never 0', async ($, on) => {
  const files = SK_FILES()
  delete files['queue/inbox/shogun.yaml']
  const r = await load($, on, files)
  expect(r.text).toContain('将/? 家/2')
})

test('shogun and karo: an inbox with an unexpected shape is ?, never 0', async ($, on) => {
  const r = await load($, on, { ...SK_FILES(), 'queue/inbox/karo.yaml': 'messages:\n- id: a\n  read: true\n- id: b\n', 'queue/inbox/shogun.yaml': inbox('maybe') })
  expect(r.text).toContain('将/? 家/? 軍済/0')
})

test('gunshi and ashigaru: the band keeps the state character and its ? rules', async ($, on) => {
  const files: Files = { ...FULL, 'queue/tasks/gunshi.yaml': task('assigned'), 'queue/tasks/ashigaru7.yaml': task('martian') }
  delete files['queue/tasks/ashigaru3.yaml']
  const r = await load($, on, files)
  expect(r.text).toContain('軍稼/0 足1済/0 足2済/0 足3?/0')
  expect(r.text).toContain('足7?/0')
})

test('before the first read, shogun and karo show no state and ? for unread', async () => {
  const text = formatLine(unknownView())
  expect(text).toContain('将/? 家/? 軍?/? 足1?/?')
})

test('an unparseable cmd file shows ? and not 0', async ($, on) => {
  const r = await load($, on, { ...FULL, 'queue/shogun_to_karo.yaml': 'garbage: [' })
  expect(r.text).toContain('進行cmd ?')
  expect(r.text).not.toContain('進行cmd 0')
})

test('an empty queue directory shows ? everywhere, never an all-clear', async ($, on) => {
  const r = await load($, on, {})
  expect(r.text).toContain('進行cmd ?')
  expect(r.text).toContain('🚨?')
  expect(r.text).not.toMatch(/\/0/)
  expect(r.text).toContain('将/? 家/? 軍?/?')
})

test('observe only: no file is written, and events pass through unchanged', async ($, on) => {
  on('tool.call', ($: any, e: any) => ({ result: 'claude code ran ' + e.tool }))
  on('prompt.submit', ($: any, e: any) => ({ text: e.text, context: e.context }))
  const r = await load($, on, FULL)
  const tool = await $.tool.call({ tool: 'Bash', command: 'rm -rf /' })
  expect(tool).toEqual({ result: 'claude code ran Bash' })
  const sub = await $.prompt.submit({ text: 'hello', context: ['ctx'] })
  expect(sub).toEqual({ text: 'hello', context: ['ctx'] })
  expect(r.writes).toEqual([])
})

test('drawing reads memory only: a redraw does not read any file', async ($, on) => {
  const r = await load($, on, FULL)
  const before = r.reads.length
  for (let i = 0; i < 3; i++) {
    const ui = await $.ui.mount({ ...AB, surface: 'terminal' })
    await ui.unmount()
  }
  expect(r.reads.length).toBe(before)
})

test('the band follows the files after the timer fires', async ($, on) => {
  const files: Files = { ...FULL }
  const clock = mock.clock(on)
  on('env.get', () => ({ value: ROOT }))
  on('fs.read', ($: any, e: any) => {
    const t = files[e.path.slice(ROOT.length + 1)]
    return t === undefined ? { deny: 'ENOENT' } : { value: t }
  })
  on('session.start', () => ({ cwd: '/work' }))
  on('ui.render', () => ({ type: 'Text', props: {}, children: ['drawn by Claude Code'] }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  files['queue/inbox/gunshi.yaml'] = inbox('false')
  await clock.advance(5000)
  const ui = await $.ui.mount({ ...AB, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /軍済\/1/ })).toBeDefined()
})
