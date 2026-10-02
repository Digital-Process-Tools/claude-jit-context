# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file carries only the latest release. The full history is in [CHANGELOG.md on the default branch](https://github.com/Digital-Process-Tools/claude-jit-context/blob/main/CHANGELOG.md).

## [0.13.0] - 2026-10-03

### Changed

- **The plugin is now `jit-context`, no longer `claude-jit-context`** (#452). If you installed from the DPT marketplace, run `/plugin install jit-context@dpt-plugins` once after updating. The marketplace's `renames` entry rewrites your `enabledPlugins` key by itself, but a git-hosted marketplace reports the plugin as not cached until that install runs. Commands move with the name: `/jit-context:doctor`, `/jit-context:init`, `/jit-context:stats`. The `claude-` prefix is reserved for Anthropic's own plugins in every marketplace, and `claude plugin validate --strict` reports it as an error. `jit-doctor.sh` recognises both names, in settings and in the plugin cache, so an install from before the rename still reads as one. The GitHub repository keeps its name.
  - Compatibility: breaking - the install ID and the slash-command namespace change; one `/plugin install jit-context@dpt-plugins` per user migrates it.

### Fixed

- **The reserved-name exception in the release smoke test now counts only errors** (#448). `claude plugin validate --strict` prints warnings as the same `❯` bullets as errors, under their own heading. The #445 check counted every bullet, so the first real `v0.12.0` run (1 error, 6 warnings) read as 7 errors and `verify` failed. Only bullets under an error heading count now, and the stated error totals must also sum to 1.

- **The hooks now start when the plugin's path contains a space** (#450). `hooks/hooks.json` ran `bash ${CLAUDE_PLUGIN_ROOT}/scripts/<hook>.sh` with the placeholder unquoted, so a plugin root such as a home directory with a space in it was split into several words. `bash` was handed a path that does not exist, and every hook failed to start without saying so: no rule fired and nothing explained why. The placeholder is now inside double quotes, as `hooks/hooks.codex.json` already had it. `claude plugin validate --strict` (CLI 2.1.287) flagged all six.

[0.13.0]: https://github.com/Digital-Process-Tools/claude-jit-context/releases/tag/v0.13.0
