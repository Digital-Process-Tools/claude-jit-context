# What the Anthropic directory validator flags, and what cleared it

Measured on jit-context, 2026-10-02 and 2026-10-03, by validating trees in the portal's
submission form (**Submit, Source, Validate**, with `owner/repo@branch`). Each finding
below was seen in the portal. Each fix is marked **confirmed** (a later scan no longer
showed it) or **applied, not yet confirmed**. The rules change without notice, so date
anything you copy from here.

claude-remember's `docs/releasing.md` covers the slim `release` branch this builds on.
This page is what came after it, the findings on the scripts themselves.

## How to test

The submission form validates **any branch**, not only the one you submit. Build the
release tree locally, push it to a throwaway branch (`release-preview`), and validate
`owner/repo@release-preview`. Do not click Next. A round trip takes a few minutes. A tag
for the same answer costs a release.

**Bisect, do not guess.** When the cause of a finding is not obvious, push several
variants at once, each with one suspect neutralised (`release-preview-a`, `-b`...), and
validate all of them. Guessing one construct at a time did not converge for us. Splitting
the hooks did: an empty hook (`echo '{}'`) cleared a finding, so it was in the content;
then library-only against hook-code-only showed that both halves carried it.

**Keep it reasonable.** About 20 throwaway branches of deliberately broken code, each
validated, can read as probing the scanner. Delete them afterwards, and say plainly in the
submission notes what was done and why.

`claude plugin validate --strict` (the CLI) is a different check. It passed on every tree
below, including ones the portal blocked. Run both.

## Read the finding's own words

Most of what we learned came from details the portal prints and that are easy to skim:
- **The list of files in a hold.** In "Scripts the validator couldn't follow", the entries
  that are not your hook scripts are the "further files" (`scripts/rebuild-tsv.sh`, `.`).
  The position of an entry in the list is not reliable evidence of which hook it came
  from. We misread it once.
- **The pair in a credential finding.** It always names a read ("reads the installer's
  PWD (file X)") and a send ("can send data off the machine (file Y: reason)"). Fix the
  side you can. The other side moves to the next candidate in the same file.

## Blocks (red, nothing goes further)

- **A typed `<<` the scanner cannot place, anywhere in a shipped script, even inside
  quotes or an awk program.** The portal files it under *"Unpinned npx launcher"*
  (`UNPINNED_NPX`), with the text "a `<<` at line N whose start or end the validator
  cannot place". Ours was an awk regex, `"[^<]<<-?..."`, in a heredoc parser, and a `<<`
  log separator inside double quotes. Fix: never type two `<` in a row. Build them
  instead, with `sprintf("%c%c", 60, 60)` in awk or `'<''<'` in bash. Here-strings `<<<`
  were not flagged. **Confirmed.**

## `COMMAND_SCRIPT_NOT_FOLLOWED`, "Scripts the validator couldn't follow" (policy hold)

The validator reads each script a hook or command runs, and stops there. Anything that
script runs, loads, or **names** goes to a reviewer.

Confirmed causes, each cleared by its fix:
1. **Here-documents** (`cmd << EOF`): "a here-document held for review, line 389, read by
   a loop". Replaced with here-strings or `printf`.
2. **`source common.sh`**, a shared library loaded by every hook. Fixed by compiling at
   release-build time. Each shipped script gets the library inlined, whole-line comments
   are stripped, and functions the script never reaches are dropped (tree-shaking). Ours
   went from a 274 KB library to scripts of 47 to 87 KB, under the 256 KiB per-file
   limit, since most of the library was comments.
3. **Naming another script in plain text.** A help message said "run
   scripts/rebuild-tsv.sh", and the hooks never ran it. Fix: name tools in words, never
   by path.

Still open as of the last scan. The hooks stay listed after all of the above, and `.`
stays in the list. Ruled out by scan variants, each one neutralised alone:
here-strings, `perl`, calling a function by a variable name (`"$fn" args`), `case`
branches whose pattern starts with `"$var"`, `awk -f <file>` with a program assembled at
run time, and awk programs passed in a variable. An empty hook clears it. Both the
library alone and the hook-specific code alone keep it. Under test: a dead
`SCRIPT_DIR="."` line, and program names (`supertool`, `perl`, `sed`, `tee`, `git`, `gh`)
appearing inside strings and regexes.

## `MCP_FORWARDS_CREDENTIAL_ENV`, "Uses a credential from the user's machine" (policy hold)

It fires on a **pair** in the same file, or across the plugin (the `plugin.json`
aggregate finding).

Read side, as cited by the portal:
- `$PWD`
- `${ANY_VAR}`
- a variable whose name contains `KEY` (our `ENTRY_KEY` array, then `_key`)
- the word "credentials"

Send side, as cited by the portal, one per scan:
- **any URL host:** `github.com`, `raw.githubusercontent.com`, `x.com` in a comment
- **network tool names in shipped data:** our bundled English word list gave `curl`,
  `ftp`, `dig`, `drill`, `mutt`
- **"perl code"**
- **"a command assembled at run time"**: our `${CLAUDE_PROJECT_DIR:-$PWD}`, and before it
  `${PWD:-$(pwd)}`

What cleared, or should clear, each one:
- **Ship a short release README** (`README.release.md`, swapped in at build time) with no
  `$VARIABLE` at all. The full README stays on `main`. **Confirmed.**
- **Do not ship `CHANGELOG.md`.** Only README and LICENSE are required, and a changelog
  line naming `${CLAUDE_PLUGIN_ROOT}` next to a link is a pair. **Confirmed.**
- **Remove example URLs** from comments and help text in shipped scripts. **Confirmed.**
- **Sweep shipped data once, broadly.** Remove every word that is also the name of a
  network, mail, chat or download client, or of a package manager: curl, wget, ftp, dig,
  drill, host, http, finger, mail, mutt, pine, elm, lynx, links, fetch, talk, pidgin,
  finch, aria, gopher, yarn, brew, apt, gem, cargo... One word per scan is a waste of
  scans. **Confirmed:** the word list stopped being cited.
- **Remove reads you do not need from shipped prose.** Our skill's example said
  `export CLAUDE_PROJECT_DIR="$PWD"`. **Confirmed.**
- **Rename variables that look like secrets.** `ENTRY_KEY` became `ENTRY_IDS`.
- **Do not inherit what you do not run.** Tree-shaking removed the `perl` helpers from
  scripts that never call them. **Applied, not yet confirmed.**
- **No `perl` in the file that reads `$PWD`.** jit-doctor's log age now comes from POSIX
  `find -mtime +N` by binary search. **Applied, not yet confirmed.**
- **No nested default expansion.** `${X:-$Y}` became an explicit `if/else`, and `$(pwd)`
  was not a better fallback. **Applied, not yet confirmed.**

## Warnings

- `ICON_MISSING`: the **listing icon is set once, at the first save or submit.** Put a
  square PNG of 512 to 2048 px at `.claude-plugin/icon.png` before you ever submit.
- `HOOK_OUTPUT_UNINSPECTED`: a `PreToolUse` hook with matcher `""` can approve any call.
  This is information for the reviewer. Nothing to do.
- `USES_HOOKS`: permanent for a hooks plugin.

## The `claude-` prefix

CLI 2.1.287 reserves plugin names starting with `claude-`, `anthropic-`, `anthropics-` or
`cc-plugin-` in **every marketplace**, not only the directory. Rename with a
`marketplace.json` `renames` entry. Claude Code then rewrites `enabledPlugins` itself, and
for a git-hosted marketplace each user runs `/plugin install <new>@<marketplace>` once.

## The portal

- **"The branch can't change while the plugin is under review."** Withdraw first.
  Withdrawing says "nothing was published", and resubmitting the same repo reopens it.
- The form takes `owner/repo@branch`, and the branch you validate is the one it tracks.

## Guards that keep these fixed

`check_release_tree.py` fails the release build on:
- a typed `<<`
- a shipped script that sources or runs another file
- a shipped script that spells `scripts/<name>.sh`

`tests/test-release-branch-461.sh` runs the hook suites against the compiled scripts, so
what ships is what was tested.
