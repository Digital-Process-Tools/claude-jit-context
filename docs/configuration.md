# Configuration

_Part of [claude-jit-context](../README.md). Full reference, not the getting-started arc._

Optional, in `.claude/jit-context/config.env`:

```bash
# What a match injects: the whole entry body (full, the default), or the entry
# title and its description: (summary, roughly 20 tokens). Set by whoever pays
# for the context window; an individual entry overrides it with `inject:`.
# Any other value is refused and named — the default stands.
# Run scripts/rebuild-tsv.sh to see what one match costs on your tree.
JIT_CONTEXT_INJECT=full

# scripts/jit-doctor.sh only. An entry body over this many bytes, and a keyword
# shorter than this many, each get an ADVISORY line. Both are advisory by
# construction: they never move doctor's exit code, so CI consuming that code
# cannot start failing over a two-character keyword.
# Doctor prints its effective value and WHERE IT CAME FROM, so a mistyped key —
# JIT_CONTEXT_DOCTOR_MAX_BYTE, singular — reads as "(default)" beside a key it
# names as unread, rather than as a setting that applied and did nothing.
JIT_CONTEXT_DOCTOR_MAX_BYTES=4096
JIT_CONTEXT_DOCTOR_MIN_KEYWORD=3

# Source-root prefix used when turning a vocabulary entry's "## Modules"
# section into path triggers. Default: src/
DYNAMIC_RULES_MODULE_PREFIX="src/"

# Extended regex of keywords too generic to index, however they were authored.
DYNAMIC_RULES_KEYWORD_BLACKLIST="^(count|output|input|name|file|files)$"

# Inject vocabulary on file paths as well as prompts. Off by default: interactive
# sessions already get a vocabulary pass on every prompt, so this would only
# duplicate context. Turn it on for autonomous runs, which send a single prompt
# for the whole run — before they know which part of the codebase they will touch.
DYNAMIC_RULES_VOCAB_PATHS=0

# The Stop hook's own "N entries injected this session, none updated" report (and
# its could-not-tell variants). Off by default (#291, #295): the audience is a human
# curating .claude/jit-context/, not the model whose turn it fires into — a completed
# subagent has woken to answer this line as though it were a task. hooks.log gets the
# same detail either way, on every session, flag or no flag; this setting only decides
# whether a copy of it also reaches the model's own context. Only 0 and 1 are
# implemented — anything else is refused, the same as an unknown JIT_CONTEXT_INJECT.
JIT_CONTEXT_STOP_REPORT=0
```

**This file is read, not executed.** One `KEY=VALUE` per line; `#` comments and blank lines are ignored, surrounding quotes are stripped, and a leading `export` is accepted. Nothing inside a value is expanded — a `$`, a backtick or a `$(…)` is a literal character.

Only settings named `JIT_CONTEXT_*`, `DYNAMIC_RULES_*` or `DVSI_*` are read. Any other line is **refused**, named in `hooks.log`, and reported once per session in the context the hooks inject — it is never dropped in silence. A recognised setting given a value this code does not implement is refused the same way: `JIT_CONTEXT_INJECT=gated` names the line and leaves the default in force, rather than reading as a mode that applied. A `#` preceded by whitespace starts a trailing comment, exactly as it did when the file was sourced; one that is not is an ordinary character, so `^(a#b)$` keeps its hash.

That narrowness is deliberate. `config.env` lives in the project, so it arrives with the repository. It was previously `.`-sourced on every prompt and every tool call, which made cloning a repo and opening it arbitrary code execution before you had read a line of the code. `PATH` is a valid shell identifier and the very next thing every hook does is run `awk`, so an allowlist of plain identifiers would not have closed it.

