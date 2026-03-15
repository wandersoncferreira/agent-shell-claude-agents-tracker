# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Compact one-line agent headers for better scannability (closes #5)
  - Collapsed: `▶ ● Explore  Search for auth...  2m [3]`
  - Expanded: Full details with description, timing, messages, prompt, output
  - Status indicators: `●` running, `✓` completed, `✗` failed
  - Unread count `[N]` visible on header line

### Fixed

- `reset-all` now shows counts of teams/tasks/agents in the confirmation prompt
- `reset-all` properly unsubscribes from all agent-shell buffers before clearing
- `reset-all` stops all timers (spinner, refresh, inbox) not just the spinner
- `reset-all` clears all hash tables including `--collapsed-messages` and `--waiting-for-response`
- `reset-all` validates paths are under `~/.claude/` before deletion (with symlink resolution)
- Spinner indicator now appears for team members when waiting for response, even if they have no prior messages or output