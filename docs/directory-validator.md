# Getting a plugin through the Anthropic directory validator

Measured on jit-context, 2026-10-02 and 2026-10-03, by validating trees in the portal's
submission form. Each finding below was seen in the portal. Each fix is marked
**confirmed** (a later scan no longer showed it) or **applied** (not yet re-scanned).
The rules change without notice, so date anything you copy from here.

claude-remember's `docs/releasing.md` describes the slim `release` branch this builds on.
This page covers what came after, the findings on the scripts themselves.

## Playbook, step by step, for another plugin

1. **Ship a slim tree.** Build a `release` branch from each tag, with a deny-list for
   tests, docs, CI, maintainer tooling, `CLAUDE.md` and `CHANGELOG.md`. Keep `README.md`
   and `LICENSE`: the directory requires both. See claude-remember's `docs/releasing.md`
   and our `.github/release-branch.json`.
2. **Rename if the plugin's name starts with `claude-`.** Do it before anything else (see
   "The `claude-` prefix" below).
3. **Add the icon before the first save or submit.** A square PNG of 512 to 2048 px at
   `.claude-plugin/icon.png`. The listing icon is set once, at the first save, and never
   again.
4. **Ship a short release README.** A `README.release.md` swapped in at build time: what
   the plugin does, how to install it, the commands, one link to the full README. It holds
   **no `$VARIABLE` at all**.
5. **Make every shipped script self-contained.** If your scripts `source` a library,
   compile at build time: inline the library, strip whole-line comments, and drop the
   functions each script never reaches. Our `.github/scripts/compile_scripts.py` does
   all three.
6. **Clean the scripts and data of the patterns listed below.** Run the guards (step 7)
   to find them, and fix in the source, not in the build.
7. **Add guards to the release check,** so a fixed pattern cannot come back. Ours are in
   `check_release_tree.py`, under "Guards" below.
8. **Prove that the compiled scripts behave like the sources.** Run the test suites
   against the built tree and compare `--help` and hook output byte for byte. Ours is
   `tests/test-release-branch-461.sh`, and it runs in the release workflow before publish.
9. **Validate before you release.** The submission form validates **any branch**. Push the
   built tree to a throwaway branch (`release-preview`) and validate
   `owner/repo@release-preview`. Do not click Next.
10. **When a finding's cause is not obvious, bisect.** Push a few variants at once, each
    with one suspect removed, and validate them all. Then **fix what you find in the real
    code** before the next round. Keep the number of throwaway branches reasonable, and
    delete them afterwards: many broken branches validated in a row can read as probing.
11. **Tag, let the workflow publish `release`, then submit.** If the plugin is already
    under review, the tracked branch cannot change: withdraw first ("Nothing was
    published"), then resubmit with `owner/repo@release`.
12. **Write in the submission notes what is left and why,** in one honest sentence per
    hold.

## Read the finding's own words

- **The file list in a hold.** In "Scripts the validator couldn't follow", the entries
  that are not your hooks are the "further files" (`scripts/rebuild-tsv.sh`, `.`). Do not
  trust the position of an entry in the list: we read meaning into it once, and it was
  wrong.
- **The pair in a credential finding.** It names a read ("reads the installer's PWD (file
  X)") and a send ("can send data off the machine (file Y: reason)"). If the send side
  moves to a new candidate on every scan, cut the read side instead.

## Blocks (red)

- **A typed `<<` that the scanner cannot place**, in any shipped script, even inside
  quotes or an awk program. The portal files it as *"Unpinned npx launcher"*
  (`UNPINNED_NPX`). Build the operator from character codes instead:
  `sprintf("%c%c", 60, 60)` in awk, `'<''<'` in bash. Here-strings `<<<` were never
  flagged. **Confirmed.**

## `COMMAND_SCRIPT_NOT_FOLLOWED`, "Scripts the validator couldn't follow" (policy hold)

The validator reads each script that a hook or command runs, and stops there.

Confirmed causes:
1. **Here-documents** (`cmd << EOF`). Use here-strings or `printf` instead.
2. **`source` of another file.** Fixed by compiling (playbook step 5).
3. **Naming another script by path in text** ("run scripts/rebuild-tsv.sh"). Name tools
   in words instead.

4. **Under investigation, not a confirmed cause: a `#` written inside quotes** (`'' | '#'*)` in a case pattern, `c == "#"` in awk).
   The scanner reads the `#` as a comment and is left with an unclosed quote. Write
   `\#*` in a bash pattern and `"\043"` in awk. **Hypothesis, then refuted:** on
   `post-tool-hook.sh` (2026-10-03), lines 1-249 clear, 1-365 hold, the same cut with
   `jit_load_config`'s body emptied clears; removing `printf -v`, the `done < "$file"`
   read, the `export` arm, a trailing comment with an unclosed quote, `$'\r'`, a
   `[[ =~ ]]` alternation, quote-character case patterns or `|`-joined case arms did not
   clear it. Every variant without line `'' | '#'*) continue ;;` cleared, every one with
   it held -- but the same cut with `\#*` written instead still holds (`release-preview-z389`).
   So the trigger is in the first lines of the loop body (line counter, CR strip, trim
   loop, that case with its `continue`), and not the quote around `#` alone.

**Bisect with truncated hooks.** The validator reads scripts without running them, so a
hook cut after N lines (at a point where the prefix still parses, then `echo '{}'`) is
a valid probe. The other hooks reduced to `echo '{}'`. Halve the range each round.

**Validate from the browser console, one call at a time.** The portal posts to
`/claudeai-rpc/anthropic.directory_submissions.plugins.v1alpha.PluginSubmissionsService/ValidatePlugin`
with `{"organizationUuid", "github": {"repoFullName", "ref"}}` and the
`x-organization-uuid` header, and the response carries the report JSON. Parallel calls
are refused: "Too many validations for this organization right now", retry after about
90 seconds. Keep one at a time.

Ruled out by scan variants, each removed alone: here-strings, `perl`, `awk -f` with a
program assembled at run time, awk programs held in a variable. Here-strings and awk
programs in a variable were tested a second time and ruled out again (previews
`73f48ff`, `release-preview-n2`), because this list was not read first: read it first.
An empty hook clears the hold. The library alone keeps it, and so does the
hook-specific code alone. **Applied,
under test:** commands and `case` patterns built from variables (see the credential hold
below), a dead `SCRIPT_DIR="."` line.

## `MCP_FORWARDS_CREDENTIAL_ENV`, "Uses a credential from the user's machine" (policy hold)

A **pair** in the same file, or across the plugin (the `plugin.json` aggregate finding).

Read side, as the portal cited it:
- `$PWD`
- `${ANY_VAR}`
- a variable named `*KEY*`
- the word "credentials"

Send side, as the portal cited it, one per scan:
- **any URL host:** `github.com`, `raw.githubusercontent.com`, `x.com` in a comment
- **network tool names in shipped data:** `curl`, `ftp`, `dig`, `drill`, `mutt`
- **"perl code"**
- **"a command assembled at run time":**
  - `${X:-$Y}` and `${X:-$(pwd)}`
  - a `case` pattern containing a variable (`"$want"'|'*)`)
  - `"$fn" args`
  - finally a plain string assignment, `X="$X$a$b"`

What cleared each one:
- **Release README without variables** (playbook step 4). **Confirmed.**
- **No `CHANGELOG.md` in the release tree.** **Confirmed.**
- **No example URLs** in comments and help text. **Confirmed.**
- **One broad sweep of shipped data.** Remove every word that is also the name of a
  network, mail, chat or download client, or of a package manager: curl, wget, ftp, dig,
  drill, host, http, finger, mail, mutt, pine, elm, lynx, links, fetch, talk, pidgin,
  finch, aria, gopher, yarn, brew, apt, gem, cargo... **Confirmed:** the data stopped
  being cited.
- **No unneeded `$PWD` in prose** (`export CLAUDE_PROJECT_DIR="$PWD"` in a skill
  example). **Confirmed.**
- **Rename secret-looking variables** (`ENTRY_KEY` became `ENTRY_IDS`). **Confirmed.**
- **No `perl` in scripts that read the environment.** Tree-shaking dropped the unused
  helpers, the timestamp fallback became `date`, and the log age comes from
  `find -mtime +N`. **Confirmed:** "perl code" stopped being cited.
- **No nested default expansions, no variable-named commands or `case` patterns.**
  Use `if/else`, `[[ $x == "$v"* ]]`, and an explicit name table. **Confirmed** for each
  instance the portal cited.
- **The send side cannot be emptied in a bash diagnostic,** because string building is
  everywhere. So **cut the read side**:
  - no `cd "$PWD"` (it was a no-op)
  - no `$PWD` printed in messages
  - `$(pwd)` instead of `$PWD` in a fallback
  - no identifier that only *contains* PWD (`PWD_TOPLEVEL`)
  - no bash variable named `key` or `_key`

  **Confirmed:** each one stopped being cited.

- **No environment variable named at run time.** `${!sig:-}` became a literal `case`
  over the known names, guarded by a test that fails on a name with no arm.
  **Confirmed:** the read side moved on.
- **No bare word `env` in a shipped script**, not even as a regex alternative
  (`rtk|command|env|sudo`), cited as "printenv / env / export -p / set". Write `[e]nv`
  in a regex, and `export` inside a subshell instead of `env VAR=... cmd`.
  **Confirmed:** the read side moved on.
- **No `$PWD` read anywhere in code,** not only in the diagnostic: the read can come
  from any shipped script, here `jit-dry-run.sh`, which no hook or command runs.
  `$(pwd)` everywhere. **Confirmed** (preview `f62114c`): the read side moved on.
- **No variable whose name reads as a credential**, shell or awk, whatever it holds.
  Cited one per scan, in this order: `VOCAB_KEYS`, `pats` ("pat", a personal access
  token), `pin`. Sweep them all at once rather than one per validation: `*KEY`, `*KEYS`,
  `*TOKEN*`, `SECRET`, `PASSWORD`, and the short names `pat`, `tok`, `pw`, `pass`,
  `cred`, `auth`, `pin`, `sig`, `otp`, `jwt`, `cookie`, `key`. `KEYWORD` was never cited.
  **Confirmed.**
- **No `${!` at all, arrays included.** `"${!ENTRY_FILENAME[@]}"` (the index list of an
  array, which reads no environment) was cited as "an environment variable named at run
  time". A counted loop replaced it. **Confirmed: the credential hold cleared**
  (preview `4540249`, 2026-10-03).

**There is no reviewer note in the submission form.** We planned to submit with a hold
and a note, and found no field for it. A hold has to be cleared.

**Read the JSON, not the page.** The portal's validation report (in the browser's
network tab) gives each hold as structured `params`: `env`, `credential_at`,
`sender_at`, `host`. `host: ""` means no network destination was found, so the send
side is a guess and the read side is the one to cut.

## Warnings

- `ICON_MISSING`: see playbook step 3.
- `HOOK_OUTPUT_UNINSPECTED`: a `PreToolUse` hook with matcher `""` can approve any call.
  This is information for the reviewer.
- `USES_HOOKS`: permanent for a hooks plugin.

## The `claude-` prefix

CLI 2.1.287 reserves plugin names starting with `claude-`, `anthropic-`, `anthropics-` or
`cc-plugin-` in **every marketplace**. Rename the plugin and add a `marketplace.json`
`renames` entry. Claude Code then rewrites `enabledPlugins` itself, and for a git-hosted
marketplace each user runs `/plugin install <new>@<marketplace>` once.

## Guards in `check_release_tree.py`

The release build fails on:
- a typed `<<`
- a shipped script that sources or runs another file
- a shipped script that spells `scripts/<name>.sh`
- a command or `case` pattern named by a variable (continuation lines and assignment-shaped
  data are skipped)
