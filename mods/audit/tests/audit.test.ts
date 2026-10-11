import { expect, test } from 'claude-code/testing'
import { AGENTS, localIso, monthOf, resolveAgent, targetFor, outcomeOf, toolRecord } from '../hooks/lib.js'

// The dummy secret. It is pushed into every place a command, URL, prompt or result can carry text,
// and must never appear in anything the mod writes (the whole argv and stdin of every process it starts).
const SECRET = 'DUMMY_SECRET_xyz'
const ROOT = '/scratch/audit-root'

type Call = { argv: string[]; stdin?: string }

// Stubs every mods-API call the mod may make, and records them. Returns what was written.
function wire(on: any, env: Record<string, string | undefined>, run?: (argv: string[], stdin?: string) => any, logDeny = false) {
  const calls: Call[] = []
  const logs: string[] = []
  const envReads: string[] = []
  on('env.get', ($: any, e: any) => {
    envReads.push(e.name)
    return { value: env[e.name] }
  })
  on('process.run', ($: any, e: any) => {
    calls.push({ argv: [...e.argv], stdin: e.init?.stdin })
    if (run) return run(e.argv, e.init?.stdin)
    return { value: { exitCode: 0, stdout: '', stderr: '' } }
  })
  on('ui.log', ($: any, e: any) => {
    logs.push(e.text)
    return logDeny ? { deny: 'no transcript' } : { value: undefined }
  })
  const tees = () => calls.filter((c) => c.argv[0] === 'tee')
  const lines = () => tees().map((c) => JSON.parse((c.stdin ?? '').trimEnd()))
  return { calls, logs, envReads, tees, lines }
}

const AS = (name: string | undefined) => ({ SHOGUN_AUDIT_ROOT: ROOT, SHOGUN_AGENT_ID: name })

// ---- what is recorded ------------------------------------------------------------------------

test('a tool call is one tee -a of one JSON line; the destination is logs/audit/YYYY-MM/<agent>.jsonl', async ($, on) => {
  const w = wire(on, AS('ashigaru1'))
  on('tool.call', () => ({ result: 'ok', text: 'ok' }))
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(w.tees().length).toBe(1)
  const argv = w.tees()[0].argv
  expect(argv.slice(0, 3)).toEqual(['tee', '-a', '--'])
  expect(argv[3]).toMatch(/^\/scratch\/audit-root\/logs\/audit\/\d{4}-\d{2}\/ashigaru1\.jsonl$/)
  const rec = w.lines()[0]
  expect(rec.agent).toBe('ashigaru1')
  expect(rec.event).toBe('tool.call')
  expect(rec.tool).toBe('Bash')
  expect(rec.ok).toBe(true)
  expect(rec.ts).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}$/)
  // The line travels on stdin, one line, newline-terminated
  expect(w.tees()[0].stdin!.endsWith('\n')).toBe(true)
  expect(w.tees()[0].stdin!.trimEnd().includes('\n')).toBe(false)
})

test('the month directory is made once, not on every event', async ($, on) => {
  const w = wire(on, AS('karo'))
  on('tool.call', () => ({ result: 'ok' }))
  for (let i = 0; i < 5; i++) await $.tool.call({ tool: 'Read', file_path: '/x/' + i })
  expect(w.calls.filter((c) => c.argv[0] === 'mkdir').length).toBe(1)
  expect(w.calls.filter((c) => c.argv[0] === 'mkdir')[0].argv.slice(0, 3)).toEqual(['mkdir', '-p', '--'])
  expect(w.tees().length).toBe(5)
  // Only mkdir and tee are ever started
  expect(w.calls.every((c) => c.argv[0] === 'mkdir' || c.argv[0] === 'tee')).toBe(true)
})

test('the default root is the repository root: logs/audit is not placed under mods/audit', async ($, on) => {
  const w = wire(on, { SHOGUN_AUDIT_ROOT: undefined, SHOGUN_AGENT_ID: 'shogun' })
  on('tool.call', () => ({ result: 'ok' }))
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  const dest = w.tees()[0].argv[3]
  expect(dest).toMatch(/\/logs\/audit\/\d{4}-\d{2}\/shogun\.jsonl$/)
  expect(dest).not.toContain('/mods/audit')
  expect(dest.startsWith('/')).toBe(true)
})

test('turn start and complete are recorded without the prompt or the answer', async ($, on) => {
  const w = wire(on, AS('gunshi'))
  on('turn.start', ($: any, e: any) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  await $.turn.start({ text: 'please use ' + SECRET, turnId: 't1' })
  await $.turn.complete({ turnId: 't1', answer: 'the key is ' + SECRET, durationMs: 1234.4, isAborted: false, reason: 'answer', usage: null })
  const [a, b] = w.lines()
  expect(a).toMatchObject({ agent: 'gunshi', event: 'turn.start', turn: 't1' })
  expect(b).toMatchObject({ agent: 'gunshi', event: 'turn.complete', turn: 't1', reason: 'answer', ms: 1234, aborted: false })
  expect(JSON.stringify(w.calls)).not.toContain(SECRET)
})

// ---- the secret is never written -------------------------------------------------------------

test('a secret in a Bash command, a WebFetch URL, a Grep pattern, MCP args or an Agent prompt is never written', async ($, on) => {
  const w = wire(on, AS('ashigaru2'))
  on('tool.call', ($: any, e: any) => ({ result: 'the result holds ' + SECRET, text: 'the result holds ' + SECRET }))
  await $.tool.call({ tool: 'Bash', command: 'curl -H "Authorization: ' + SECRET + '" https://x.example/' })
  await $.tool.call({ tool: 'WebFetch', url: 'https://x.example/?token=' + SECRET, prompt: SECRET })
  await $.tool.call({ tool: 'Grep', pattern: SECRET, path: '/a' })
  await $.tool.call({ tool: 'Glob', pattern: SECRET + '/**' })
  await $.tool.call({ tool: 'mcp__srv__do', arg: SECRET })
  await $.tool.call({ tool: 'Agent', prompt: SECRET, description: SECRET })
  await $.tool.call({ tool: 'WebSearch', query: SECRET })
  expect(w.tees().length).toBe(7)
  // Everything the mod handed to a process: argv and stdin
  expect(JSON.stringify(w.calls)).not.toContain(SECRET)
  // Only names and outcomes
  const tools = w.lines().map((r) => r.tool)
  expect(tools).toEqual(['Bash', 'WebFetch', 'Grep', 'Glob', 'mcp__srv__do', 'Agent', 'WebSearch'])
  for (const r of w.lines()) expect(Object.keys(r).sort()).toEqual(['agent', 'event', 'ok', 'tool', 'ts'])
})

test('a secret in a prompt reaching the turn, or in a file the tools read or write, is not written; only the path is', async ($, on) => {
  const w = wire(on, AS('ashigaru3'))
  on('tool.call', () => ({ result: SECRET, text: SECRET }))
  await $.tool.call({ tool: 'Read', file_path: '/work/a.md', offset: 1, limit: 5 })
  await $.tool.call({ tool: 'Write', file_path: '/work/b.md', content: SECRET })
  await $.tool.call({ tool: 'Edit', file_path: '/work/c.md', old_string: SECRET, new_string: SECRET })
  await $.tool.call({ tool: 'NotebookEdit', notebook_path: '/work/d.ipynb', new_source: SECRET })
  expect(JSON.stringify(w.calls)).not.toContain(SECRET)
  expect(w.lines().map((r) => [r.tool, r.file_path])).toEqual([
    ['Read', '/work/a.md'],
    ['Write', '/work/b.md'],
    ['Edit', '/work/c.md'],
    ['NotebookEdit', '/work/d.ipynb'],
  ])
})

test('a path argument of a non-file tool is not recorded (Grep path, Bash cwd-like fields, MCP file_path)', async ($, on) => {
  const w = wire(on, AS('ashigaru3'))
  on('tool.call', () => ({ result: 'ok' }))
  await $.tool.call({ tool: 'Grep', pattern: 'x', path: '/some/dir' })
  await $.tool.call({ tool: 'mcp__srv__do', file_path: '/some/file' })
  for (const r of w.lines()) expect(r.file_path).toBeUndefined()
})

test('a path under the secrets directory is recorded and flagged; a Bash command naming it is not recorded at all', async ($, on) => {
  const w = wire(on, AS('ashigaru4'))
  on('tool.call', () => ({ result: 'ok' }))
  await $.tool.call({ tool: 'Read', file_path: '/home/u/.config/multi-agent-shogun/secrets.env' })
  await $.tool.call({ tool: 'Bash', command: 'cat /home/u/.config/multi-agent-shogun/secrets.env' })
  await $.tool.call({ tool: 'Read', file_path: '/home/u/projects/x.md' })
  const [a, b, c] = w.lines()
  expect(a.file_path).toBe('/home/u/.config/multi-agent-shogun/secrets.env')
  expect(a.sensitive).toBe(true)
  expect(JSON.stringify(b)).not.toContain('secrets.env')
  expect(c.sensitive).toBeUndefined()
})

test('a subagent call is marked sub; its id is not written', async ($, on) => {
  const w = wire(on, AS('karo'))
  on('tool.call', () => ({ result: 'ok' }))
  await $.tool.call({ tool: 'Read', file_path: '/a', agentId: 'agent-SECRETISH-123' })
  expect(w.lines()[0].sub).toBe(true)
  expect(JSON.stringify(w.calls)).not.toContain('agent-SECRETISH-123')
})

// ---- the agent name --------------------------------------------------------------------------

test('every name on the list writes its own file', async () => {
  expect(AGENTS.length).toBe(10)
  for (const name of AGENTS) {
    expect(resolveAgent(name)).toBe(name)
    expect(targetFor('/r', new Date(2026, 9, 12), name).file).toBe('/r/logs/audit/2026-10/' + name + '.jsonl')
  }
})

test('names that are not on the list resolve to no agent, hence to _unknown.jsonl', async () => {
  const bad: (string | undefined)[] = [undefined, '', ' ', 'ashigaru8', 'ashigaru0', 'ASHIGARU1', 'ashigaru1 ', ' karo', '../x', '../../etc/passwd', 'karo/../shogun', 'shogun\n', 'a/b', '..', '.', 'shogun.jsonl', 'ashigaru10']
  for (const v of bad) {
    expect(resolveAgent(v)).toBeNull()
    expect(targetFor('/r', new Date(2026, 9, 12), resolveAgent(v)).file).toBe('/r/logs/audit/2026-10/_unknown.jsonl')
  }
})

for (const v of [undefined, '', 'ashigaru8', '../x', 'karo/../shogun', 'KARO']) {
  test('through the mod: name ' + JSON.stringify(v) + ' -> _unknown.jsonl with agent "?" and the raw value written nowhere', async ($, on) => {
    const w = wire(on, AS(v))
    on('tool.call', () => ({ result: 'ok' }))
    await $.tool.call({ tool: 'Read', file_path: '/a' })
    const dest = w.tees()[0].argv[3]
    expect(dest).toMatch(/\/logs\/audit\/\d{4}-\d{2}\/_unknown\.jsonl$/)
    expect(w.lines()[0].agent).toBe('?')
    if (v) expect(JSON.stringify(w.calls)).not.toContain(v)
    // no path other than the one _unknown file is ever named
    expect(w.calls.every((c) => !c.argv.join(' ').includes('..'))).toBe(true)
  })
}

test('the name is read from SHOGUN_AGENT_ID once, not on every event', async ($, on) => {
  const w = wire(on, AS('ashigaru5'))
  on('tool.call', () => ({ result: 'ok' }))
  for (let i = 0; i < 4; i++) await $.tool.call({ tool: 'Read', file_path: '/a' })
  expect(w.envReads.filter((n) => n === 'SHOGUN_AGENT_ID').length).toBe(1)
})

// ---- outcomes --------------------------------------------------------------------------------

test('success, error and denial are told apart without copying any text of the result', async ($, on) => {
  const w = wire(on, AS('ashigaru6'))
  const answers = [{ result: 'fine' }, { isError: true, result: SECRET, text: SECRET }, { deny: SECRET }]
  let i = 0
  on('tool.call', () => answers[i++])
  await $.tool.call({ tool: 'Bash', command: 'a' })
  await $.tool.call({ tool: 'Bash', command: 'b' })
  await $.tool.call({ tool: 'Bash', command: 'c' })
  const r = w.lines()
  expect([r[0].ok, r[0].outcome]).toEqual([true, undefined])
  expect([r[1].ok, r[1].outcome]).toEqual([false, 'error'])
  expect([r[2].ok, r[2].outcome]).toEqual([false, 'denied'])
  expect(JSON.stringify(w.calls)).not.toContain(SECRET)
})

test('outcomeOf and toolRecord on shapes the stubs cannot produce (a thrown call, a non-object result, hostile names)', async () => {
  expect(outcomeOf(undefined)).toEqual({ ok: false, outcome: 'unknown' })
  expect(outcomeOf(null)).toEqual({ ok: false, outcome: 'unknown' })
  expect(outcomeOf('x')).toEqual({ ok: false, outcome: 'unknown' })
  const d = new Date(2026, 9, 12, 10, 30, 0, 123)
  expect(toolRecord(d, 'karo', { tool: 'Bash', command: SECRET }, { ok: false, outcome: 'threw' })).toMatchObject({ tool: 'Bash', ok: false, outcome: 'threw' })
  // a tool name with spaces, quotes or control characters is not echoed
  expect(toolRecord(d, 'karo', { tool: 'Ba sh"\n' + SECRET }, { ok: true }).tool).toBe('?')
  expect(toolRecord(d, 'karo', {}, { ok: true }).tool).toBe('?')
  expect(toolRecord(d, null, { tool: 'Read', file_path: 7 }, { ok: true })).toMatchObject({ agent: '?' })
  expect(toolRecord(d, null, { tool: 'Read', file_path: 7 }, { ok: true }).file_path).toBeUndefined()
  // an over-long path is cut
  expect(toolRecord(d, 'karo', { tool: 'Read', file_path: '/' + 'a'.repeat(5000) }, { ok: true }).file_path!.length).toBe(1024)
  expect(JSON.stringify(toolRecord(d, 'karo', { tool: 'Bash', command: SECRET }, { ok: true }))).not.toContain(SECRET)
})

// ---- time and month --------------------------------------------------------------------------

test('the month directory follows the event time: the last second of a month and the first of the next', async () => {
  expect(monthOf(new Date(2026, 9, 31, 23, 59, 59, 999))).toBe('2026-10')
  expect(monthOf(new Date(2026, 10, 1, 0, 0, 0, 0))).toBe('2026-11')
  expect(monthOf(new Date(2027, 0, 1, 0, 0, 0, 0))).toBe('2027-01')
  expect(targetFor('/r', new Date(2026, 10, 1), 'karo')).toEqual({ dir: '/r/logs/audit/2026-11', file: '/r/logs/audit/2026-11/karo.jsonl' })
  expect(localIso(new Date(2026, 9, 12, 10, 30, 5, 7))).toMatch(/^2026-10-12T10:30:05\.007[+-]\d{2}:\d{2}$/)
})

// ---- failure never reaches the agent ---------------------------------------------------------

test('when nothing can be written the tool result is unchanged and one warning is left, not one per event', async ($, on) => {
  const w = wire(on, AS('ashigaru7'), () => ({ deny: 'EACCES: permission denied' }))
  on('tool.call', ($: any, e: any) => ({ result: 'ran ' + e.tool, text: 'ran ' + e.tool }))
  for (let i = 0; i < 4; i++) {
    expect(await $.tool.call({ tool: 'Bash', command: 'ls' })).toEqual({ result: 'ran Bash', text: 'ran Bash' })
  }
  expect(w.logs.length).toBe(1)
  expect(w.logs[0]).toContain('audit log not written')
  expect(w.logs[0]).not.toContain('ls')
})

test('a nonzero exit of tee or mkdir counts as a failed write too', async ($, on) => {
  const w = wire(on, AS('ashigaru7'), () => ({ value: { exitCode: 1, stdout: '', stderr: 'Permission denied' } }))
  on('tool.call', () => ({ result: 'ok' }))
  expect(await $.tool.call({ tool: 'Bash', command: 'ls' })).toEqual({ result: 'ok' })
  expect(w.logs.length).toBe(1)
  // mkdir failed, so no tee was tried
  expect(w.tees().length).toBe(0)
})

test('after a failure the mod writes again once the disk allows it, and warns again on a second streak', async ($, on) => {
  let broken = true
  const w = wire(on, AS('karo'), () => (broken ? { deny: 'EROFS' } : { value: { exitCode: 0, stdout: '', stderr: '' } }))
  on('tool.call', () => ({ result: 'ok' }))
  await $.tool.call({ tool: 'Read', file_path: '/a' })
  await $.tool.call({ tool: 'Read', file_path: '/a' })
  expect(w.logs.length).toBe(1)
  broken = false
  await $.tool.call({ tool: 'Read', file_path: '/a' })
  expect(w.tees().length).toBe(1)
  broken = true
  await $.tool.call({ tool: 'Read', file_path: '/a' })
  expect(w.logs.length).toBe(2)
})

test('even if the warning cannot be shown, the call goes through', async ($, on) => {
  const w = wire(on, AS('karo'), () => ({ deny: 'EACCES' }), true)
  on('tool.call', () => ({ result: 'ok' }))
  expect(await $.tool.call({ tool: 'Read', file_path: '/a' })).toEqual({ result: 'ok' })
  expect(w.logs.length).toBe(1)
})

test('a relative SHOGUN_AUDIT_ROOT is refused: nothing is started, the call goes through, one warning', async ($, on) => {
  const w = wire(on, { SHOGUN_AUDIT_ROOT: 'relative/dir', SHOGUN_AGENT_ID: 'karo' })
  on('tool.call', () => ({ result: 'ok' }))
  expect(await $.tool.call({ tool: 'Read', file_path: '/a' })).toEqual({ result: 'ok' })
  expect(w.calls.length).toBe(0)
  expect(w.logs.length).toBe(1)
})

test('a failure of env.get is the unknown-name case, not a stop', async ($, on) => {
  const calls: Call[] = []
  on('env.get', ($: any, e: any) => (e.name === 'SHOGUN_AUDIT_ROOT' ? { value: ROOT } : { deny: 'env unavailable' }))
  on('process.run', ($: any, e: any) => {
    calls.push({ argv: [...e.argv], stdin: e.init?.stdin })
    return { value: { exitCode: 0, stdout: '', stderr: '' } }
  })
  on('ui.log', () => ({ value: undefined }))
  on('tool.call', () => ({ result: 'ok' }))
  expect(await $.tool.call({ tool: 'Read', file_path: '/a' })).toEqual({ result: 'ok' })
  expect(calls.find((c) => c.argv[0] === 'tee')!.argv[3]).toMatch(/_unknown\.jsonl$/)
})

// ---- observe only ----------------------------------------------------------------------------

test('observe only: results of every shape come back as they were, and nothing but mkdir/tee/env.get/ui.log is called', async ($, on) => {
  const w = wire(on, AS('shogun'))
  const shapes: any[] = [{ result: 'a', text: 'a' }, { result: { x: 1 }, context: ['c'] }, { isError: true, result: 'e', text: 'e' }, { deny: 'no' }]
  let i = 0
  on('tool.call', () => shapes[i++ % shapes.length])
  for (const s of shapes) expect(await $.tool.call({ tool: 'Bash', command: 'x' })).toEqual(s)
  // any call the mod made that no stub answers would have been a failure and a warning
  expect(w.logs).toEqual([])
  for (const c of w.calls) expect(['mkdir', 'tee']).toContain(c.argv[0])
  expect(w.envReads.sort()).toEqual(['SHOGUN_AGENT_ID', 'SHOGUN_AUDIT_ROOT'])
})

test('observe only: the turn events and the prompt pass through; a prompt is not touched', async ($, on) => {
  wire(on, AS('shogun'))
  on('turn.start', ($: any, e: any) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: 'shown under the answer' }))
  on('prompt.submit', ($: any, e: any) => ({ text: e.text, context: e.context }))
  on('prompt.section', () => ({ text: 'section' }))
  on('prompt.context', () => ({ blocks: ['ctx'] }))
  expect(await $.turn.start({ text: 'hi', turnId: 't9' })).toEqual({ turnId: 't9' })
  expect(await $.turn.complete({ turnId: 't9', answer: 'a', durationMs: 5, isAborted: false, reason: 'answer', usage: null })).toEqual({ text: 'shown under the answer' })
  expect(await $.prompt.submit({ text: 'hello', context: ['c1'] })).toEqual({ text: 'hello', context: ['c1'] })
})
