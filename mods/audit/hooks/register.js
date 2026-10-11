// shogun-audit: observe-only audit log.
// Appends one JSON line per tool call and per turn start/complete to logs/audit/YYYY-MM/<agent>.jsonl.
// It never denies, answers or rewrites an event: every hook ends in next(e) / returns what next(e) gave.
// It draws nothing (no ui.render) and a failure to write never reaches the agent.
import { resolveAgent, targetFor, outcomeOf, toolRecord, turnStartRecord, turnCompleteRecord, toLine } from './lib.js'

// A hung tee must not stall the agent: the call is killed and counts as a failed write.
const WRITE_TIMEOUT_MS = 2000

// $.fs.write replaces a file (there is no append), and its 4 MiB limit would silently end the log.
// So each record is one `tee -a` (O_APPEND, one write) with the line on stdin - never on the command line.
// argv is fixed in shape: only the destination path varies, and it is built from a closed list of names.

// Cached after the first read: the environment does not change while the session runs.
let agentName // undefined = not read yet; null = not a known agent
let rootPath // undefined = not read yet; null = unusable

// Month directory already created (mkdir only when the month changes)
let madeDir = ''
// Warn once per failure streak, not once per event
let warned = false

async function readAgent($) {
  if (agentName !== undefined) return agentName
  let v
  try {
    v = await $.env.get('SHOGUN_AGENT_ID')
  } catch (err) {
    v = undefined
  }
  agentName = resolveAgent(v)
  return agentName
}

// SHOGUN_AUDIT_ROOT lets a test point the log at a scratch directory (default: the repository root).
// A relative path is refused: a relative write would land wherever the session's cwd happens to be.
async function readRoot($) {
  if (rootPath !== undefined) return rootPath
  let override
  try {
    override = await $.env.get('SHOGUN_AUDIT_ROOT')
  } catch (err) {
    override = undefined
  }
  let root = typeof override === 'string' && override !== '' ? override : $.plugin.root.replace(/\/+$/, '').split('/').slice(0, -2).join('/')
  root = root.replace(/\/+$/, '')
  rootPath = root.startsWith('/') ? root : null
  return rootPath
}

async function runOk($, argv, init) {
  const r = await $.process.run(argv, { ...init, timeoutMs: WRITE_TIMEOUT_MS })
  if (r.exitCode !== 0) throw new Error(argv[0] + ' exited ' + r.exitCode)
}

async function warn($, err) {
  if (warned) return
  warned = true
  try {
    // The one place a failure is left: a dim line in this session's transcript, which the model does not read.
    // When even that fails there is nowhere left to say it, so it is dropped.
    const why = String(err && err.message ? err.message : err).slice(0, 160)
    await $.ui.log('audit log not written (' + why + '); work continues unchanged')
  } catch (err2) {
    // nowhere left
  }
}

// Never throws: whatever goes wrong here must not reach the tool call, the prompt or the model.
async function record($, d, build) {
  try {
    const agent = await readAgent($)
    const root = await readRoot($)
    if (root === null) throw new Error('log root is not an absolute path')
    const { dir, file } = targetFor(root, d, agent)
    if (madeDir !== dir) {
      await runOk($, ['mkdir', '-p', '--', dir])
      madeDir = dir
    }
    await runOk($, ['tee', '-a', '--', file], { stdin: toLine(build(agent)) })
    warned = false
  } catch (err) {
    // Re-check the directory next time, in case it was what failed
    madeDir = ''
    await warn($, err)
  }
}

export function register(on) {
  // Each tool call is recorded once, after it finished, with its outcome. The result is returned exactly as it came.
  on('tool.call', async ($, e, next) => {
    let result
    try {
      result = await next(e)
    } catch (err) {
      const at = new Date()
      await record($, at, (agent) => toolRecord(at, agent, e, { ok: false, outcome: 'threw' }))
      throw err
    }
    const at = new Date()
    await record($, at, (agent) => toolRecord(at, agent, e, outcomeOf(result)))
    return result
  }).catch(async ($, e, next) => {
    // Should this hook itself ever fail: let the call through unchanged (before next) or hand back the result it already produced (after next)
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    const at = new Date()
    await record($, at, (agent) => turnStartRecord(at, agent, e))
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const at = new Date()
    await record($, at, (agent) => turnCompleteRecord(at, agent, e))
    return next(e)
  })
}
