# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file carries only the latest release. The full history is in [CHANGELOG.md on the default branch](https://github.com/Digital-Process-Tools/claude-jit-context/blob/main/CHANGELOG.md).

## [0.12.0] - 2026-10-02

### Added

- **Ported claude-remember's slim `release` branch for the Anthropic plugin
  directory** (#437). `main` keeps everything; `.github/workflows/release-branch.yml`
  now builds a `release` branch from each pushed `vX.Y.Z` tag, dropping `tests/`,
  `docs/`, `.github/`, `.oss/`, `.claude/`, `.agents/`, `outbound/`, `changelog.d/`,
  `trap.d/` and the maintainer-only dotfiles (`.github/release-branch.json`'s
  deny-list), cutting `CHANGELOG.md` to its latest section, and rewriting removed-path
  links to `main`. `.github/scripts/check_release_tree.py` enforces the directory's
  pre-submission rules (under 512 files, no non-image file of 256 KiB or more) and
  `.github/scripts/smoke_release_tree.py` runs every hook in `hooks/hooks.json` once,
  isolated, before anything is pushed. `data/generic-words.txt` (1,027,699 bytes) was
  split into `data/generic-words/chunk-NN.txt`, each under 256 KiB, since it is read by
  `rebuild-tsv.sh` and `jit-misses.sh` on a user's own machine and cannot simply be
  denied; `--generic-words PATH` and `JIT_CONTEXT_GENERIC_WORDS` still accept a single
  plain file, unchanged. `docs/releasing.md` has the full sequence.

### Fixed

- **`session-start-hook.sh`'s log-rotation note misreported when `JIT_CONTEXT_LOG_MAX_BYTES` was malformed** (#423). A non-numeric, negative, or leading-zero value made `jit_log_rotate()` silently refuse to rotate, while the size-watch note formatted the same value through `awk '{ printf "%.1f", $1 / 1000000 }'` and said "rotates automatically past 0.0 MB" -- claiming rotation was on when it had actually done nothing. The note now validates the value the same way `jit_log_rotate()` does and names the refused value instead.

- **`pre-tool-hook.sh` silently answered `{}` when `CLAUDE_PROJECT_DIR` contained a backslash escape sequence** (#424). `tools_base`/`vocab_base` used to be built in bash and handed to the decisive awk as `-v` values, and awk's `-v` processes backslash escapes in the value it receives -- a Windows-shaped path mangled `JIT_BASE` before any rule lookup ran, so every rule under `tools/` or `vocabulary/` silently failed to match. Both now read `JIT_BASE` through `ENVIRON`, already exported for the same reason #402/#378 fixed `JIT_WORKTREE_NOTE` this way.

- **`test-session-markers.sh` section G planted its "foreign" fixture at a fixed name in shared `/tmp`, following a symlink** (#428). The plant used `printf ... > "/tmp/claude-hook-log-999999.tmp"`, which opens `O_CREAT|O_TRUNC` and follows a symbolic link with no `[ -L ]` check first. On a shared host or multi-tenant runner, a co-tenant who pre-created that path as a symlink got the link target truncated the next time the suite ran, while the assertion still passed (the link resolves) and the trailing `rm -f` removed only the link, so the suite reported green. The fixture now lives under the suite's own private, mode-0700 `mktemp -d` tree, matching `tests/test-hook-tmpfile.sh` section D, so a co-tenant can no longer plant anything at that path before the suite runs.

- **A `~` Bash rule no longer matches a heredoc body** (#432). A `tools/00-manual/*.md`
  rule whose `match:` is a `~` regex -- and a plain `require:`/`forbid:` rule beside it --
  was tested against the whole command text, heredoc body included, so a word inside a
  heredoc payload (data piped to whatever the operator line names, not a command) could
  refuse a call that never ran the word at all. The false block was reproducible against
  `supertool 'batch:@-'` payloads that legitimately mention `find`/`wc` inside a TOML
  heredoc, and against this very issue body when it was filed.

  `jit_strip_heredoc_body()` (new, in `scripts/common.sh`) now removes every heredoc BODY
  line -- and its own closing delimiter line -- from the command text before the fold that
  feeds all three matchers runs, leaving the heredoc OPERATOR line itself untouched so a
  rule can still target whatever actually runs on that line. Guarded against a here-string
  (`<<<word`), which opens no body and must not be mistaken for one.

  Self-review found three sharper edges and closed all three before this shipped: a
  `<<WORD`-shaped line that is not a genuine heredoc opener (an ordinary quoted string
  that happens to contain the shape) no longer swallows every line after it -- a genuine
  closing delimiter is now required, found by scanning ahead, before anything strips;
  a backslash-quoted delimiter (`<<\DELIM`) is now recognized, the same job a quoted
  delimiter does with different spelling; and a heredoc piped to a known interpreter
  (`bash`/`sh`/`ssh`/`python3`/...) is left alone, because its body is the command that
  runs, not a payload -- stripping it would have let a forbidden word slip past a
  `forbid:`/`~`/`block` row inside `bash <<EOF ... EOF` that correctly blocks the same
  word as a bare command.

- **SessionStart no longer prints a "nothing to do" line for a hooks.log size it cannot
  act on** (#434). The size-watch note, `scripts/session-start-hook.sh`, fired on every
  session whose log sat between `jit-misses.sh`'s 10 MB watch threshold and a
  well-formed, non-zero `JIT_CONTEXT_LOG_MAX_BYTES` (20 MB by default) -- rotation was
  already automatic in that band (#406), so the line said so and then said there was
  nothing to do, on every such session, teaching readers to skip `JIT :` lines.

  That branch is gone. A person still hears about the log in the two states that carry
  an actual instruction: `JIT_CONTEXT_LOG_MAX_BYTES=0` (rotation off -- delete or rotate
  it yourself) and an invalid value (rotation did not run this session, and the refused
  value is named). A well-formed, non-zero max between the two thresholds is silent now.

- **`commands/{doctor,init,stats}.md` no longer grant bare `Bash`** (#439). All three
  carried `allowed-tools: Bash`, which grants every shell command, not just the one
  diagnostic script each command exists to run -- the Anthropic directory holds this as
  unrestricted shell access, the hold `fix/437`'s release-tree check pinned as a known,
  already-filed exception rather than blocking on.

  The grant now names the actual script: `Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/jit-doctor.sh:*)`
  and its two siblings. Narrowing it correctly meant the body's own first words had to be
  byte-identical to the grant, which the previous body never was: `#405`'s fix wrapped the
  whole invocation in `bash -c 'IFS=" " read -r -a ... <<< "${1:-}"; exec bash
  "$2/scripts/X.sh" ...'` to force the zsh-incompatible `read -a` splitting of `$ARGUMENTS`
  into a real bash regardless of what shell ran the command body -- so the body's first word
  was always `bash -c`, and no grant naming the script itself could ever match it.

  The splitting moves into each script instead, behind a synthetic `--arguments-string`
  flag. Getting the substitution itself right took a second pass: the first attempt kept
  `"${ARGUMENTS:-}"` (braced, with a default) in the body, meant to reach the script
  unresolved and be split there -- but a real `claude -p` run showed Claude Code never
  substitutes a braced form, so it stays open shell syntax in the executed command, and the
  Bash tool holds ANY command containing unresolved `${...}` or `$?` for approval regardless
  of whether it matches the grant's own prefix ("Contains expansion"). That would have
  denied every invocation, typed arguments or none, defeating the fix outright. The body
  instead uses the bare, unbraced `$ARGUMENTS`, which Claude Code DOES substitute with the
  raw typed text before the command reaches the shell or the permission check, the same way
  `${CLAUDE_PLUGIN_ROOT}` already does -- so `jit-doctor.sh`/`jit-init.sh`/`jit-stats.sh` each
  build the `read -a` array from an already-resolved, quoted literal string, and #405 (zsh)
  and #278 (glob expansion of an unquoted `$ARGUMENTS`) both stay fixed.

  This substitution choice has a real trade against #278's own original design, and self-
  review (an `Explore` and an `oss:auditor` spawn against the committed diff) caught that
  the first cut of this fragment understated it. The body first quoted `$ARGUMENTS` with
  DOUBLE quotes; a real `claude -p` run showed that was not merely a narrow quote-escape but
  full, unscoped shell execution with no quote-breakout needed at all -- bash still expands
  `$(...)`, backticks and `$VAR` *inside* double quotes, confirmed with `--base foo
  $(touch /tmp/pwned)` actually running the `touch`. The body now quotes `$ARGUMENTS` with
  SINGLE quotes instead, which bash never expands inside at all, closing `$(...)`, backticks,
  `$VAR` and `"` all at once. The one character still live is a literal `'`, confirmed the
  same way with `--base foo' ; touch /tmp/pwned ; echo '`. #278's own `"${ARGUMENTS:-}"`
  closed this by never splicing raw text into the command at all, but that design is the one
  a narrowed grant always denies (above) -- the actual tension this issue sits on: an
  injection-proof mechanism and a narrowed `allowed-tools` grant cannot both be had under
  Claude Code's current permission model. The single-quote residual is bounded the same way
  #278 itself bounded its own, narrower case (the invoking user's own typed text, on their
  own machine), though it is a materially wider bound than #278's: that one could at worst
  splice stray filenames as extra arguments, this one is unscoped shell execution for the one
  character that still breaks out. Whether that one character is actually caught at runtime
  is not something this fix controls -- three different things were separately observed to
  intervene during testing (the "Contains expansion" permission check, a sandboxed test
  environment's own file-write restrictions, and an agent's own judgment refusing a
  suspicious-looking argument), none of them a structural guarantee, which is why this stays
  documented as an open residual rather than a closed one.

  Verified against a real `claude -p` run (`--permission-mode manual --permission-prompts
  none`, no `--dangerously-skip-permissions`, no `--allowedTools` -- the default
  `defaultMode: auto` in this machine's own `~/.claude/settings.json` otherwise masks the
  grant check behind its own classifier): the narrowed grant lets
  `/claude-jit-context:doctor` run clean with no `permission_denials`; a deliberately wrong
  grant (`commands/doctor.md`'s `allowed-tools` renamed to `jit-init.sh` while its body still
  calls `jit-doctor.sh`) is DENIED even for the exact, unmodified body command with no
  trailing shell metacharacters at all; a typed `--base <tree>` argument reaches the script
  as `resolved from --base on the command line`; a typed `--base decoy-glob-*` argument
  against a directory holding matching files comes through as the literal string
  `decoy-glob-*`, never expanded; and, with the final single-quote body, a typed
  `--base foo $(touch /tmp/pwned)` runs clean with no permission prompt and never creates the
  file, confirming the command substitution is genuinely inert rather than merely unapproved.

- **Two 0.12.0 release-audit leftovers: a dead jit-context rule for the split wordlist, and a smoke test that read a missing `ps` as clean** (#441).

  `.claude/jit-context/paths/00-manual/generic-words-data.md`'s `match:` still named
  `data/generic-words.txt`, the single flat file #437 split into `data/generic-words/chunk-NN.txt`
  files for the Anthropic plugin directory's 256 KiB per-file limit. The flat file no longer
  exists, so the rule had been inert since #437 landed -- firing on nothing real, the #83 shape
  one directory further in. The `match:` now targets `data/generic-words/chunk-[0-9]+[.]txt$`,
  the index was rebuilt, and `tests/test-dogfood-entries.sh` gained both directions: it fires on
  a chunk and stays silent on the old flat-file path, on the split's own `README.md` (which is
  documentation, not a wordlist `rebuild-tsv.sh` reads), and on a lookalike directory name.
  `scripts/jit-misses.sh --help` and `docs/diagnostics.md` named the same stale path as the
  default; both now say `data/generic-words/`. A stale comment in `scripts/rebuild-tsv.sh`
  pointing at the same old path, immediately above the already-correct code, is fixed the same way.

  `.github/scripts/smoke_release_tree.py`'s `_survivors()` caught `OSError` from `ps` and
  returned `[]` -- the same shape as "ps ran and found no survivors". `_reap()`'s first poll
  would then declare the run clean on the very first call, never having actually checked a
  single process, and surface no error anywhere. The bug is latent on `ubuntu-latest`, which has
  `ps`, so nothing in CI today would have caught a regression here. `_survivors()` now returns
  `None` for "could not tell", distinct from an empty list for "ran and found nothing", and
  `_reap()` turns a `None` into a `result.errors` entry that makes the whole smoke run report
  not-ok rather than silently clean. `tests/test-smoke-release-tree-survivors-441.sh` drives both
  functions directly: a positive control where `ps` genuinely runs, and a stubbed-missing-`ps`
  negative (both for `_survivors()` alone and for `_reap()`'s caller path), each paired so the
  negative cannot pass on emptiness alone.

- **The release-branch smoke test lets the reserved-name `--strict` error through as a warning** (#445). CLI 2.1.287, the version `release-branch.yml` pins, rejects names starting with `claude-` as reserved, so the first real `verify` run would have failed and pushed nothing. The directory itself has not objected to this listing's name, and a rename changes every install ID. So that one error becomes a loud `::warning::`, and only when it is the only error: every other `--strict` failure still fails the run. Ported from claude-5h-window-spread #20.

### Security

- **A `tool_input` string value could pose as a JSON key and repoint `tool_name`/`command`, bypassing every `mode: block` rule** (#426). `pre-tool-hook.sh`, `pre-path-hook.sh` and `post-tool-hook.sh` each read the payload positionally: every quoted field at an even split position was treated as a candidate key, with no check that it actually sat at key position (followed by `:`) and no brace-depth tracking to tell a top-level field from one nested inside `tool_input`. A `tool_input` value equal to `tool_name`, `command`, `file_path`, `pattern`, `skill` or `subagent_type` could therefore repoint the field it named, last-wins, to whatever quoted string happened to follow it in the payload -- byte-identical to a genuine non-match, so a blocked call ran silently. `jit_hook_fields()` (`common.sh`) replaces the positional read with a structural one: a string is a key only when the next raw piece begins with `:`, and a value is read only at the correct depth -- the payload's own top level for `tool_name`, directly inside `tool_input` and nowhere deeper for everything else -- first-wins throughout.

- **`JIT_MISSING_REQUIRES` was the one exec-crossing list in `common.sh` with no byte cap, so an oversized `requires:` value in a committed `00-index.tsv` could trip `E2BIG` and refuse -- or, on an unwritable `TMPDIR`, silently pass -- every tool call in a session** (#427). Every sibling list that crosses the same `pre-tool-hook.sh` exec boundary (`JIT_SYMLINKS`, `JIT_NONFILES`, `JIT_CONFIG_REFUSED`, `JIT_LAYERS_REFUSED`, `JIT_ENTRY_AGES`) was already capped; this one was not. `jit_missing_requires()` now refuses any `requires:` value that is not a bare binary name (`^[A-Za-z0-9._+-]{1,255}$`) before it is ever added to the list, and bounds the accumulated list to a few KB with a sentinel that reports the truncation rather than silently dropping it -- the same discipline `rebuild-tsv.sh` now also applies at index time, refusing to index a row whose `requires:` value does not match.

- **A `mode: block`/`require:`/`forbid:` rule could fail open behind a heredoc-shaped line that never actually opened one** (#442). `jit_strip_heredoc_body()` (#432) treated any `<<WORD`-shaped text as a real heredoc operator whenever a later line happened to equal WORD, with no awareness of quoting or comments, so `echo "<<EOF"` followed by an unrelated later `EOF` line, or a `# <<EOF` comment line (whole-line or trailing), hid every line between them from the rules that only ever see `fold_full`. A single-quoted argument spanning several physical lines hid a real command the same way, since the quote state was never carried from one line into the next. Fixed by requiring a genuine, quote-free, non-comment operator line -- tracked across the whole command text, not reset per line -- before anything is treated as a real heredoc opener.
  Separately, and more structurally: deciding whether a recognized heredoc body is safe to strip used to rest on a DENYLIST of interpreters known to execute their stdin (bash, sh, ssh, python3, a dot-source special case, ...), stripped for everything else. That denylist is itself unbounded and fails OPEN on anything it has never heard of -- `$SHELL <<EOF`, `perl5.30 <<EOF`, `node18 <<EOF`, `awk -f - <<EOF` (which can run arbitrary code via `system()`), `"$0" <<EOF` all silently had their bodies stripped and hidden from a block rule, purely because none of them matched a name on the list. Inverted to an ALLOWLIST of known payload sinks instead (`cat`/`tee` writing to a file, this repository's own `supertool`, `git commit -F -`, `gh ... --body-file -`/`-F -`): a heredoc body is now stripped ONLY when the operator line matches one of them, so an unrecognized command keeps its body visible by default rather than the reverse. Naming a command as a sink is not enough on its own, though: the same body can still reach an interpreter by piping the sink's own stdout onward (`cat <<EOF | bash`, `tee f <<EOF | sh`) or via command/process substitution reading it back as a command (`cat <<EOF >(bash)`, `eval "$(cat <<EOF"`), none of which a plain file write, `tee`, `supertool`, `git commit -F -` or `gh --body-file -` ever legitimately shares a line with -- a `|`, a `$(`, a backtick, a `>(` or a `<(` anywhere on the operator line now overrides the allowlist unconditionally.
  That default-visible direction is the safe one for a deny-style rule (`forbid:`/`~`/`mode: block`) but the UNSAFE one for `require:`, an allow-only-if-present check that the extra visibility would let be satisfied by inert heredoc-body text that was never a real argument at all. `require:` now reads its own fold, built by stripping every recognized heredoc body unconditionally regardless of the sink allowlist, so it can never be satisfied by payload text no matter what command carries it.
  Every change in both rounds narrows what gets stripped for `forbid:`/`~`/`mode: block`, and widens what gets stripped for `require:` -- both are the fail-closed direction for the rule family they serve, so #432's own tests (a heredoc body genuinely written to a file is not command text) are unaffected and still pass. Tests cover all three original repros, the trailing-comment and multi-line-quote gaps found in self-review, the five concrete denylist bypasses, the pipe/substitution bypass on a named sink, and the real sinks the allowlist must not swallow, run across every awk engine found on the machine (awk, gawk, mawk).

[0.12.0]: https://github.com/Digital-Process-Tools/claude-jit-context/releases/tag/v0.12.0
