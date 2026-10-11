// shogun-status: observe-only status band for the shogun's claude.
// Reads queue/ and dashboard.md on a timer, keeps the result in `view`, and draws it above the prompt.
// It never answers, rewrites or denies an event, and never writes a file.
import { AGENTS, parseCommands, parseAlerts, parseTaskState, parseUnread, unknownView, formatLine } from './lib.js'

const REFRESH_MS = 5000

// What the band shows. Module-level, so ui.render reads memory and never a file.
let view = unknownView()
let drawn = ''

// Where queue/ and dashboard.md live. SHOGUN_STATUS_ROOT lets a test point the mod at a dummy queue.
async function rootDir($) {
  const override = await $.env.get('SHOGUN_STATUS_ROOT')
  if (override) return override.replace(/\/+$/, '')
  // mods/status -> repository root
  return $.plugin.root.replace(/\/+$/, '').split('/').slice(0, -2).join('/')
}

async function readText($, path) {
  try {
    return await $.fs.read(path)
  } catch (err) {
    return null
  }
}

async function collect($) {
  const root = await rootDir($)
  const next = unknownView()
  const cmds = await readText($, root + '/queue/shogun_to_karo.yaml')
  next.cmds = cmds === null ? { ok: false, reason: 'unreadable' } : parseCommands(cmds)
  const dash = await readText($, root + '/dashboard.md')
  next.alerts = dash === null ? { ok: false, reason: 'unreadable' } : parseAlerts(dash)
  for (let i = 0; i < AGENTS.length; i++) {
    // shogun and karo have no task file: not read, no state shown
    if (AGENTS[i].task !== false) {
      const task = await readText($, root + '/queue/tasks/' + AGENTS[i].name + '.yaml')
      next.agents[i].state = task === null ? { ok: false, reason: 'unreadable' } : parseTaskState(task)
    }
    const inbox = await readText($, root + '/queue/inbox/' + AGENTS[i].name + '.yaml')
    next.agents[i].inbox = inbox === null ? { ok: false, reason: 'unreadable' } : parseUnread(inbox)
  }
  return next
}

async function refresh($) {
  try {
    view = await collect($)
  } catch (err) {
    view = unknownView()
  }
  const line = formatLine(view)
  // Redraw only when the text changed
  if (line !== drawn) {
    drawn = line
    $.ui.invalidate('ui.render')
  }
}

// The one refresh timer. session.start can fire again (after a reload of this mod), and a timer per call would multiply the reads.
let timer = null

export function register(on) {
  on('session.start', async ($, e, next) => {
    await refresh($)
    // Stop the previous timer before arming a new one, so only one is ever running
    if (timer) timer.cancel()
    timer = $.clock.every(REFRESH_MS, () => refresh($))
    return next(e)
  })

  // Draw only. No file access here: this runs on every redraw.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const { Box, Text } = $.ui.resolve(e)
    const mine = Text({ children: [formatLine(view)], wrap: 'truncate' })
    const theirs = await next(e)
    if (!theirs) return mine
    return Box({ flexDirection: 'column', children: [mine, theirs] })
  })
}
