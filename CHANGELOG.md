# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] — First public release

The system had been running in production for months while its documentation still
described a design that no longer existed. This release makes the package match the code,
and publishes it.

### Published

- The repository is public, and CI runs on every push and pull request.
- README rebuilt around what the plugin is for rather than how it works: the receipt
  (1,000 entries, 2.58 MB in the project it was extracted from), five pillars, and the
  signal that tells a reader when to reach for it — the agent rediscovering something the
  team already knows.
- `.claude/jit-context/` — the repo now uses its own plugin across all three dimensions,
  including a `block` rule that refuses hand edits of a generated index.
- The layer table no longer advertises what is not shipped. `rebuild-tsv.sh` indexes
  `00-manual/` alone, while the hooks scan all four layers, so `10-auto/`, `20-grouped/`
  and `30-crosscutting/` work only when a generator writes its own `00-index.tsv`. No
  generator ships with this plugin.
- The `Bash` path-scanning section is framed as compatibility rather than a companion-tool
  plug: anything reaching a file outside the file tools carries no `file_path`, so path
  rules would go quiet with nothing in the log.

### Added

- **Vocabulary dimension**, triggered by keywords in the prompt via a `UserPromptSubmit`
  hook. It had existed and worked for months without appearing anywhere in the README.
- `scripts/session-start-hook.sh` — clears per-session `once` markers so rules fire fresh.
- `.claude/jit-context/config.env`, sourced by `common.sh`, for per-project settings:
  `DYNAMIC_RULES_MODULE_PREFIX`, `DYNAMIC_RULES_KEYWORD_BLACKLIST`,
  `DYNAMIC_RULES_VOCAB_PATHS`.
- `tests/run-all.sh` — one entry point, non-zero exit on any failure.
- GitHub Actions CI: the full suite on Linux and macOS, plus shellcheck.
- A vocabulary example. The dimension had no example at all.

### Changed

- **Rules are configured by YAML frontmatter in the `.md` file itself.** The previous
  `config.json` per directory is gone, along with the `jq` dependency. `rebuild-tsv.sh`
  parses frontmatter into `00-index.tsv`, and the hooks read only TSV — one `awk`
  process per hook, no JSON parsing at runtime. Typical hook time is 30–110 ms.
- Keyword matching is **space-bounded** after CamelCase splitting and lowercasing.
  Substring matching was the old behaviour and made short keywords fire on everything.
- The source-root prefix used for module path triggers is configurable and defaults to
  `src/`; it was hardcoded to one project's layout.
- `DVSI_AUTONOMOUS_VOCAB_PATHS` is renamed `DYNAMIC_RULES_VOCAB_PATHS`. The old name is
  still honoured so existing runners do not break silently.
- README rewritten. The previous one documented the removed `config.json` format, listed
  `jq` as a requirement, and never mentioned the vocabulary dimension.

### Fixed

- Examples carried no frontmatter, so every shipped example was inert on arrival.
- A keyword containing dots or slashes could never match, because the matcher strips
  those characters from the prompt before comparing. `rebuild-tsv.sh` now normalizes
  keywords identically at build time.
- shellcheck warnings across `rebuild-tsv.sh` (SC2034, SC2155, SC2188).

## [0.1.0]

Initial internal version: tool and path rules, configured through `config.json`.
