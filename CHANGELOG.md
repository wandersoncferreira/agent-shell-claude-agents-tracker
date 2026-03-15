# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed

- All faces now inherit from standard Emacs faces instead of hardcoded hex colors (closes #9)
  - Works with any Emacs theme (dark, light, high-contrast)
  - Uses: `success`, `error`, `warning`, `shadow`, `font-lock-type-face`, `font-lock-keyword-face`, `link`

### Fixed

- `reset-all` now shows counts of teams/tasks/agents in the confirmation prompt
- `reset-all` properly unsubscribes from all agent-shell buffers before clearing
- `reset-all` stops all timers (spinner, refresh, inbox) not just the spinner
- `reset-all` clears all hash tables including `--collapsed-messages` and `--waiting-for-response`
- `reset-all` validates paths are under `~/.claude/` before deletion (with symlink resolution)
- Spinner indicator now appears for team members when waiting for response, even if they have no prior messages or output