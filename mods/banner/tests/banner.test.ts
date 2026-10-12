import { expect, test } from 'claude-code/testing'
import { ROLES, formatBanner, resolveRole } from '../hooks/lib.js'

// ---- the whole mod, through Claude Code's events -------------------------------------------

const AB = {
  plugin: 'shogun-banner',
  component: 'AbovePrompt',
  requestId: 'band',
  viewport: { columns: 188, rows: 50 },
  props: { hasSurvey: false, isWorking: false, maxRows: 3, bodyColumns: 186, scroll: { offset: 0, bodyRows: 3 }, view: {} },
} as const

const NAMES: Array<[string, string]> = [
  ['shogun', '将軍'],
  ['karo', '家老'],
  ['gunshi', '軍師'],
  ['ashigaru1', '足軽一番'],
  ['ashigaru2', '足軽二番'],
  ['ashigaru3', '足軽三番'],
  ['ashigaru4', '足軽四番'],
  ['ashigaru5', '足軽五番'],
  ['ashigaru6', '足軽六番'],
  ['ashigaru7', '足軽七番'],
]

// Loads the mod with SHOGUN_AGENT_ID answered by `env`. Every call that is not an environment read is recorded.
async function load($: any, on: any, env: () => any, below?: () => any) {
  const envReads: string[] = []
  const others: string[] = []
  on('env.get', ($: any, e: any) => {
    envReads.push(e.name)
    return env()
  })
  for (const ev of ['fs.read', 'fs.write', 'process.run', 'http.fetch']) {
    on(ev, () => {
      others.push(ev)
      return { deny: 'not expected' }
    })
  }
  on('session.start', (_: any, e: any) => ({ cwd: e.cwd }))
  on('ui.render', below ?? (() => ({ type: 'Text', props: {}, children: ['drawn by Claude Code'] })))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  return { envReads, others }
}

async function banner($: any) {
  const ui = await $.ui.mount({ ...AB, surface: 'terminal' })
  const t = await ui.find({ type: 'Text', text: /⚔/ })
  const below = await ui.find({ type: 'Text', text: /drawn by Claude Code/ })
  await ui.unmount()
  return { text: t ? String(t.children.join('')) : undefined, below: below !== undefined }
}

// ---- allowed side: the ten names -----------------------------------------------------------

for (const [id, shown] of NAMES) {
  test(`${id} is drawn as ${shown}`, async ($, on) => {
    await load($, on, () => ({ value: id }))
    const r = await banner($)
    expect(r.text).toBe('⚔ ' + shown)
  })
}

test('the table holds exactly the ten names of the roster', async () => {
  expect(Object.keys(ROLES)).toEqual(NAMES.map(([id]) => id))
  for (const [id, shown] of NAMES) expect(resolveRole(id)).toBe(shown)
})

test('each banner is one short line', async () => {
  for (const [id] of NAMES) {
    const line = formatBanner(resolveRole(id))
    expect(line).not.toContain('\n')
    expect(Array.from(line).length).toBeLessThanOrEqual(8)
  }
})

// ---- refused side: anything else is '?', never empty and never a guess ---------------------

test('unset SHOGUN_AGENT_ID is ?', async ($, on) => {
  await load($, on, () => ({ value: undefined }))
  expect((await banner($)).text).toBe('⚔ ?')
})

test('names outside the roster are ?', async ($, on) => {
  const bad = ['ashigaru8', 'ashigaru0', 'ashigaru', 'ASHIGARU1', 'Shogun', 'shogun ', ' karo', 'ashigaru1\n', '', 'toString', '__proto__', 'constructor', '../karo', 'karo;x', 'ashigaru10']
  for (const v of bad) expect(resolveRole(v)).toBeNull()
  for (const v of [undefined, null, 3, true, {}, ['karo']]) expect(resolveRole(v as unknown as string)).toBeNull()
  // and through the mod: a name outside the roster is drawn as ?, not as the nearest role
  await load($, on, () => ({ value: 'ashigaru8' }))
  expect((await banner($)).text).toBe('⚔ ?')
})

test('an empty string is ?, not an empty banner', async ($, on) => {
  await load($, on, () => ({ value: '' }))
  const r = await banner($)
  expect(r.text).toBe('⚔ ?')
  expect(formatBanner(null)).toBe('⚔ ?')
})

test('a failure of env.get is ?, not a stop', async ($, on) => {
  await load($, on, () => ({ deny: 'env unavailable' }))
  const r = await banner($)
  expect(r.text).toBe('⚔ ?')
  expect(r.below).toBe(true)
})

// ---- observe only --------------------------------------------------------------------------

test('the name is read from SHOGUN_AGENT_ID once, not on every draw or restart of the session', async ($, on) => {
  const w = await load($, on, () => ({ value: 'karo' }))
  for (let i = 0; i < 4; i++) await banner($)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  expect(w.envReads).toEqual(['SHOGUN_AGENT_ID'])
})

test('drawing reads memory only: no file, process or network call happens, before or after a draw', async ($, on) => {
  const w = await load($, on, () => ({ value: 'gunshi' }))
  const before = w.envReads.length
  for (let i = 0; i < 3; i++) await banner($)
  expect(w.envReads.length).toBe(before)
  expect(w.others).toEqual([])
})

test('events pass through unchanged', async ($, on) => {
  on('tool.call', ($: any, e: any) => ({ result: 'claude code ran ' + e.tool }))
  on('prompt.submit', ($: any, e: any) => ({ text: e.text, context: e.context }))
  const w = await load($, on, () => ({ value: 'ashigaru3' }))
  const tool = await $.tool.call({ tool: 'Bash', command: 'rm -rf /' })
  expect(tool).toEqual({ result: 'claude code ran Bash' })
  const sub = await $.prompt.submit({ text: 'hello', context: ['ctx'] })
  expect(sub).toEqual({ text: 'hello', context: ['ctx'] })
  expect(w.others).toEqual([])
})

test('session.start passes through unchanged', async ($, on) => {
  await load($, on, () => ({ value: 'shogun' }))
  expect(await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/elsewhere' })).toEqual({ cwd: '/elsewhere' })
})

// ---- with another band above the prompt ----------------------------------------------------

test('what is already above the prompt stays beneath the banner', async ($, on) => {
  await load($, on, () => ({ value: 'shogun' }))
  const ui = await $.ui.mount({ ...AB, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /⚔ 将軍/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /drawn by Claude Code/ })).toBeDefined()
  await ui.unmount()
})

test('banner sits first, a band from another Mod (the status band) and the engine row follow, in that order', async ($, on) => {
  // the layer below is what mods/status returns: a Text band, here with the engine's own row under it in a column
  await load($, on, () => ({ value: 'shogun' }), () => ({
    type: 'Box',
    props: { flexDirection: 'column' },
    children: [
      { type: 'Text', props: { wrap: 'truncate' }, children: ['進行cmd 2 [cmd_226] │ 🚨1 │ 家老idle/0'] },
      { type: 'Text', props: {}, children: ['drawn by Claude Code'] },
    ],
  }))
  const ui = await $.ui.mount({ ...AB, surface: 'terminal' })
  const rows = (await ui.findAll({ type: 'Text' })).map((n: any) => String(n.children.join('')))
  await ui.unmount()
  expect(rows).toEqual(['⚔ 将軍', '進行cmd 2 [cmd_226] │ 🚨1 │ 家老idle/0', 'drawn by Claude Code'])
})
