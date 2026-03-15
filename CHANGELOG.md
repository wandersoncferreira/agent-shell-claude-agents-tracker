# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed

- `reset-all` now shows counts of teams/tasks/agents in the confirmation prompt
- `reset-all` properly unsubscribes from all agent-shell buffers before clearing
- `reset-all` stops all timers (spinner, refresh, inbox) not just the spinner
- `reset-all` clears all hash tables including `--collapsed-messages` and `--waiting-for-response`
- `reset-all` validates paths are under `~/.claude/` before deletion (with symlink resolution)
