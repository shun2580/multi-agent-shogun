// shogun-banner: observe-only role banner.
// Reads SHOGUN_AGENT_ID once at session start and draws one line above the prompt: the agent's role.
// It never answers, rewrites or denies an event, and never writes a file or runs a process.
import { resolveRole, formatBanner } from './lib.js'

// What the banner shows. Module-level, so ui.render reads memory and never an environment variable or a file.
// Until the name has been read it is '?': an empty or guessed banner is never shown.
let line = formatBanner(null)

// The name is read once: the environment does not change while the session runs.
let read = false

async function readRole($) {
  let v
  try {
    v = await $.env.get('SHOGUN_AGENT_ID')
  } catch (err) {
    v = undefined
  }
  return resolveRole(v)
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    if (!read) {
      read = true
      line = formatBanner(await readRole($))
      $.ui.invalidate('ui.render')
    }
    return next(e)
  })

  // Draw only. No env, file or process access here: this runs on every redraw.
  // Whatever is already drawn above the prompt (the engine's, or another Mod's such as the status band) stays beneath this line.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const { Box, Text } = $.ui.resolve(e)
    const mine = Text({ children: [line], wrap: 'truncate', bold: true })
    const theirs = await next(e)
    if (!theirs) return mine
    return Box({ flexDirection: 'column', children: [mine, theirs] })
  })
}
