// shogun-banner: pure name resolution and formatting. No I/O here, so every function is testable on plain values.
//
// Rule: when the agent's name is missing or not on the list, the banner says '?'.
// It never shows an empty banner and never guesses a role.

// The only names the banner accepts, with how each is shown. A value outside this table is not a name.
export const ROLES = {
  shogun: '将軍',
  karo: '家老',
  gunshi: '軍師',
  ashigaru1: '足軽一番',
  ashigaru2: '足軽二番',
  ashigaru3: '足軽三番',
  ashigaru4: '足軽四番',
  ashigaru5: '足軽五番',
  ashigaru6: '足軽六番',
  ashigaru7: '足軽七番',
}

export const UNKNOWN_MARK = '?'
const MARK = '⚔ '

// Exact match against the table. A value such as '../x', 'ashigaru1 ', 'ASHIGARU1', 'toString' or a non-string is not a name.
export function resolveRole(value) {
  return typeof value === 'string' && Object.prototype.hasOwnProperty.call(ROLES, value) ? ROLES[value] : null
}

// The one line shown above the prompt. null (unknown) is '?'.
export function formatBanner(role) {
  return MARK + (role === null ? UNKNOWN_MARK : role)
}
