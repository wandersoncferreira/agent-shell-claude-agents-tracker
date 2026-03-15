# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed

- All faces now inherit from standard Emacs faces instead of hardcoded hex colors (closes #9)
  - Works with any Emacs theme (dark, light, high-contrast)
  - Uses: `success`, `error`, `warning`, `shadow`, `font-lock-type-face`, `font-lock-keyword-face`, `link`
- Replaced animated spinner with static `⏳` indicator (closes #8)
  - Removes ~25 lines of spinner-related code
  - Eliminates timer that fired every 100ms and redrew the buffer
  - Simpler, less CPU-intensive
- Replaced inbox polling timer with file watchers (closes #15)
  - Event-driven: fires immediately when Claude Code writes to inbox
  - Eliminates 5-second polling timer
  - More responsive (instant vs up to 5s delay)
  - Less CPU usage (no periodic parsing of unchanged files)

### Added

- Summary line below header showing agent counts and unread messages (closes #4)
  - Example: `3 agents: 2 running, 1 completed | 2 unread`
  - Omits zero-count segments for cleaner display
- Compact one-line agent headers for better scannability (closes #5)
  - Collapsed: `▶ ● Explore  Search for auth...  2m [3]`
  - Expanded: Full details with description, timing, messages, prompt, output
  - Status indicators: `●` running, `✓` completed, `✗` failed
  - Unread count `[N]` visible on header line

### Fixed

- `reset-all` now shows counts of teams/tasks/agents in the confirmation prompt
- `reset-all` properly unsubscribes from all agent-shell buffers before clearing
- `reset-all` stops all timers (refresh, inbox watchers)
- `reset-all` clears all hash tables including `--collapsed-messages` and `--waiting-for-response`
- `reset-all` validates paths are under `~/.claude/` before deletion (with symlink resolution)
- Waiting indicator now appears for team members when waiting for response, even if they have no prior messages or output
- File watcher now only redraws when `config.json` changes, not on any file change in teams directory (closes #14)