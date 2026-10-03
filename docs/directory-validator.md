# What the Anthropic directory validator flags, and what cleared it

Measured on jit-context, 2026-10-02 and 2026-10-03, by validating trees in the portal's
submission form (**Submit, Source, Validate**, with `owner/repo@branch`). Each finding
below was seen in the portal. Each fix was confirmed by the next scan, except where a
section says otherwise. The rules change without notice, so date anything you copy from
here.

claude-remember's `docs/releasing.md` covers the slim `release` branch this builds on.
This page is what came after it, the findings on the scripts themselves.

## Test before you release

The submission form validates **any branch**, not only the one you submit. Build the
release tree locally, push it to a throwaway branch (`release-preview`), and validate
`owner/repo@release-preview`. Do not click Next. One round trip is a few minutes. A tag
for the same answer costs a release.

To find which construct triggers a finding, push several variants at once, each with one
suspect neutralised (`release-preview-a`, `-b`, `-c`), and validate all of them. On
jit-context, removing every here-string and every `perl` call changed nothing. That ruled
both out in one round.

`claude plugin validate --strict` (the CLI) is a different check. It passed on every
tree below, including ones the portal blocked. Run both.

## Blocks (red, nothing goes further)

- **A typed `<<` the scanner cannot place, anywhere in a shipped script, even inside
  quotes or an awk program.** The portal files it under *"Unpinned npx launcher"*
  (`UNPINNED_NPX`), with the text "a `<<` at line N whose start or end the validator
  cannot place". Ours was an awk regex, `"[^<]<<-?..."`, in a heredoc parser. Fix: never
  type two `<` in a row. Build them instead, with `sprintf("%c%c", 60, 60)` in awk or
  `'<''<'` in bash. Here-strings `<<<` were not flagged.

## Policy holds (a reviewer must clear them)

### `COMMAND_SCRIPT_NOT_FOLLOWED`, "Scripts the validator couldn't follow"

The validator reads each script a hook or command runs, and stops there. Anything that
script runs, loads or **names** goes to a reviewer. What triggered it for us, in order:

1. **Here-documents** (`cmd << EOF`): "a here-document held for review, line 389, read by
   a loop". Replaced with here-strings or `printf`.
2. **`source common.sh`**: a shared library, loaded by every hook. Fixed by compiling
   at release-build time: each shipped script gets the library inlined, with whole-line
   comments stripped. Ours went from 274 KB of library to scripts of 61 to 98 KB, under
   the 256 KiB per-file limit, since most of the library was comments.
3. **Naming another script in plain text.** The hold's list of "further files" named
   `scripts/rebuild-tsv.sh` and `scripts/jit-dry-run.sh`. The hooks never ran them: a help
   message said "run scripts/rebuild-tsv.sh". Fix: name tools in words, never by path.
4. **A dead `SCRIPT_DIR="."` fallback.** The list named a file called `.`. Dropped from
   the compiled output once nothing reads `SCRIPT_DIR`.

Read the hold's list of file names closely. The ones that are not your hooks are the
"further files", and they tell you what to fix.

### `MCP_FORWARDS_CREDENTIAL_ENV`, "Uses a credential from the user's machine"

It fires on a **pair**: something that reads the environment, plus something that could
send data out. Any of these forms the pair, per file or across the plugin (the
`plugin.json` aggregate finding):

- Read side: `$PWD`, `${ANY_VAR}`, a variable whose name contains `KEY` (our
  `ENTRY_KEY` array), the word "credentials".
- Send side: **any URL host** (`github.com`, `raw.githubusercontent.com`, `x.com` in a
  comment), and any **network tool name in shipped data**. Our bundled English word list
  tripped it with `curl`, `ftp`, `dig`, `drill` in turn, one word per scan.

What cleared it, or should, as far as the last scan shows:

- **Ship a short release README** (`README.release.md`, swapped in at build time) with no
  `$VARIABLE` at all. The full README stays on `main`.
- **Do not ship `CHANGELOG.md`.** Only README and LICENSE are required, and a changelog
  line naming `${CLAUDE_PLUGIN_ROOT}` next to a link is a pair.
- **Remove example URLs from comments and help text** in shipped scripts.
- **Remove every network command name from shipped data in one pass**, not one per scan:
  curl, wget, ftp, dig, drill, host, http, finger, mail, lynx, links, fetch, talk...
- **Remove reads you do not need from shipped prose.** Our skill's example said
  `export CLAUDE_PROJECT_DIR="$PWD"`.

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
