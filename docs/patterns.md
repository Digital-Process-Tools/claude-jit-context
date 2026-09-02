# Patterns are awk, not PCRE

_Part of [claude-jit-context](../README.md). Full reference, not the getting-started arc._

Every regex — a `paths` `match`, and a `tools` `match` prefixed with `~` — is compiled by
**awk**, so it is a POSIX ERE. PCRE shorthand classes do not exist there, and the failure
is silent: measured on `awk version 20200816`, `~gh\s+pr` compiles to `ghs+pr` and matches
nothing at all, while awk exits 0. Nothing about the rule looks wrong afterwards.

| Do not write | Write instead    |
| ------------ | ---------------- |
| `\s` `\S`    | `[[:space:]]`    |
| `\d` `\D`    | `[0-9]`          |
| `\w` `\W`    | `[A-Za-z0-9_]`   |
| `\b` `\B`    | anchor explicitly, e.g. `(^\|[;&\|\n] *)` |

`\b` fails differently and is worth knowing separately: awk *does* define it, as a
backspace character, so `\bgit\b` compiles to a pattern looking for literal backspaces
rather than word boundaries. It matches nothing either way, and is refused the same way.

**A backslash before an accented or CJK character is refused as well.** There is nothing
to reach for instead: drop the backslash and the character matches itself. This one is
worth stating because it used to be the quiet exception — the guard reads *bytes*, since
`LC_ALL=C` is pinned on every `awk` that reaches this guard — `pre-tool-hook.sh`,
`pre-path-hook.sh` and `jit-dry-run.sh`'s pattern probes — and no byte above `0x7F` belongs
to any character class under `C`, so the check that catches `\s` could not see `\é` at all.
Both
engines then dropped the backslash and matched the bare character, which is not what the
author wrote; and on gawk — which is `awk` on most Linux boxes — the hook additionally
wrote `regexp escape sequence … is not a known regexp operator` into the session while
exiting 0.

`\n` is the one escape that survives, and rules need it: `^` anchors the whole command
string rather than each line, so a rule meant to catch a command on line three of a
heredoc must anchor on `(^|[;&|\n] *)`.

**Double quotes in a pattern are yours to use.** A matching pair around the *whole* value
is read as YAML-style quoting and removed — `match: "~ls[[:space:]]+-la"` indexes as
`~ls[[:space:]]+-la`. A quote anywhere else is part of the pattern and reaches the index
untouched, which is what lets you anchor on a quoted argument at all:

```yaml
match: ~echo[[:space:]]+["]hi["]     # fires on echo "hi", not on echo hi
```

Quoting the whole value is never *required* — the reader takes the rest of the line as it
stands — so the shortest advice is to leave a pattern containing quotes unquoted, and to
write a literal quote at either end as `["]`, the bracket form the invocation macros emit.
A value that merely begins and ends with a quote without being one quoted string, such as
`"a" or "b"`, is left exactly as written rather than half-unwrapped.

Earlier versions deleted every quote in the value, so `["]` became `[]` and the rule
matched something the author never wrote, with nothing in the entry or the log to show it.

**A pattern the matcher cannot honour is refused at load and reported** — the row is
skipped, every other rule in the file keeps working, and the hook injects a notice naming
the construct and the row — `paths/00-manual row 3`, one line per refused row up to the
bound described below — once per session. Two
things this replaces: a rule that read as enforced for as long as it existed, and a single
malformed pattern (`~a[b` is a fatal awk error) that silenced every rule in its index at
once.

**A blocked call gets the notice too, after the block reason.** It used to be withheld
there, to keep a block reason the only thing the model read. That cost more than it bought:
a refused row whose entry file cannot be read is only counted on a command that row
actually matched, so when that is the same command a `block` rule refuses, every call that
would report it is blocked and the notice never arrives at all. The block itself is
structural — the call is refused whatever is read afterwards — so the reason keeps its
place at the top and the notice follows it. A blocked call does **not** spend the
once-per-session budget: the row scan stops at the rule that blocked, so the list beside a
block reason can be short, and the complete one still arrives on the next call that is not
blocked.

**The notice locates a refused row by position, never by its file name.** The index arrives
with the repository, so that column is untrusted text, and the notice fires with no rule
matched — quoting it back would be a channel into the model's context that needs no trigger.
The name you need in order to fix it is in `hooks.log`, which a person reads and no model
does, and in `jit-dry-run.sh`, which the notice points you at. That linter prints a file
name **only when the name is a plain name** — letters, digits, dot, dash and underscore, at
most 64 bytes — and `<withheld: not a plain name>` when it is not, so following the notice's
own advice does not quietly undo what the notice withheld. The row's `match` pattern is
still printed verbatim, on its own line marked `untrusted>`: a linter that will not show you
your own pattern has no reason to exist, and it is also how a row whose name was withheld
stays identifiable. `rebuild-tsv.sh` withholds a name by the same rule for the same reason.
The layer directory beside the file name is tree text too and is withheld by that rule as
well, but the linter prints it as the shorter `<withheld>`: that column is a fixed width,
and the long form pushed every column right of it out of line. `rebuild-tsv.sh` has no
fixed-width layer column, so it prints the long form throughout.

**The list of refused rows is bounded, and the count beside it is not.** The index arrives
with the repository, so the number of unhonourable rows in it is chosen by whoever wrote
it — and one bullet per row would spend the context window this plugin exists to protect.
Past roughly 4 KB the notice stops listing and says so, in those words; the total it
reports is always the true total, and the row numbers it did list are true positions in
the file, not places in the shortened list. Every row is still evaluated: the bound is on
what gets said, never on what gets checked.

**An entry the JSON channel cannot carry is refused, and its neighbours still arrive.** A
hook answers in a JSON object, and JSON is UTF-8. An entry saved in ISO-8859-1 — one `é` in
`Préferez rm -i`, which `file` reports as `ISO-8859 text` and no editor complains about —
used to travel into that object byte for byte, so a strict reader rejected the **whole**
response: the two clean entries injected in the same call were lost with it, and a `block`
decision that had been reached could not be read. The entry is now refused like an
unhonourable pattern — named by position, everything else delivered — and text that is
valid UTF-8, accents and emoji included, is unchanged.

On the tool dimension a rule whose **body** cannot be delivered still blocks, and says so in
place of its text: `mode`, `require` and `forbid` all come from the index row, so the
decision was reached and throwing it away would turn an unreadable rule into an allowed
call. When the bad bytes are in the **row** itself those are the decision inputs, there is
no verdict to preserve, and the row is refused like an unhonourable pattern — the call is
not blocked, and the notice says a block rule is the one that went dark rather than leaving
that to be guessed. `rebuild-tsv.sh` names such a row at build time, by entry file, so the
first you hear of it is not a row number in someone's session — unless the entry's file
name is not a plain `[A-Za-z0-9._-]` name, in which case the report says so instead of
printing it. Those reports are read by agents as often as by people, and a file name
arrives with the repository.

A row whose entry file cannot be opened at all — a stale index naming a file you deleted —
is refused the same way instead of reading as a rule that matched nothing.

**Nothing on the way to an entry may be a symbolic link** — not the entry file, not its
layer directory, not the dimension directory, not `config.env`, and not `.claude/` or
`.claude/jit-context/` themselves. All of them are refused through that same channel, named the same way. The
hooks read every entry with the privileges of your session, and `.claude/` arrives with the
repository: a link is a file outside the project being handed to the model by a directory
the reader has not audited, and `git clone` recreates every one of those shapes. The check
does not resolve the link, so one pointing back inside the tree is refused too; keep a copy
there, or generate the layer. Directories *above* your project are yours rather than the
clone's and are not checked, so a project reached through a symlinked parent works
normally.

**A tree carrying an implausible number of symbolic links is refused whole.** The check
above has to hold the links it found, and that has a size; past it, a repository could
choose a number large enough to disable every rule including the ones guarding it. Above the
budget no rule in that tree runs, and the hook says why. An honest tree records zero links
and never comes near it.

**An entry file name may not begin with a dot.** That is the one constraint on the name, and
it exists because the symbolic-link check above is a glob-and-`lstat` sweep of the tree: a
glob does not match a leading dot, so `.hidden.md` was invisible to it and a link named that
way was read. Nothing else about the name is constrained — spaces, accents and any other
character an author actually types stay honourable — and `rebuild-tsv.sh` cannot produce a
dot-name in the first place, so no entry you wrote is affected. An index row naming one is
refused and reported, and `jit-dry-run.sh` refuses the same row.

**An entry path that is not a regular file is refused, and the rule around it still runs.**
A row can name a directory — `dirent.md/` with a file inside it, which git commits happily —
or leave the file column empty, which points the read at the layer directory itself. On the
`awk` macOS ships, reading either one is a fatal error rather than a failed read: the hook
died mid-decision, printed no JSON at all, and a `block` rule further down the same index
did not block. The check has to run in `bash`, because `awk` cannot ask whether a path is a
file before opening it, so it rides the sweep that is already walking the tree. The row is
refused and named; every other rule in that index, including a `block` rule after it, fires
exactly as before. A FIFO at an entry path is refused by the same test — reading one would
hang the hook rather than fail it.

### Compatibility — tools that touch files through `Bash`

Path rules read `file_path` from `Read`/`Edit`/`Write`/`Glob`/`Grep`. Anything that reaches a file some other way does not carry that field, and a naive implementation would stop matching the moment a session used one — every path rule you wrote would go quiet, with no error and nothing in the log to explain it.

So `Bash` commands are scanned too: **a token counts as a path being touched when it names a file or directory that exists inside the project.** That covers `sed -i src/Billing/Totals.php`, `vim src/Billing/Totals.php`, a test runner pointed at a directory, or a batching wrapper such as [supertool](https://github.com/Digital-Process-Tools/claude-supertool), whose quoted arguments are unpacked so that

```bash
./supertool 'read:src/Billing/Totals.php' 'grep:getAmount:src/Billing/:10'
```

still fires the rules for `src/Billing/`.

Existence on disk is what makes that safe to guess at. A word in a commit message, a branch name, a flag or a package name is not a file in your checkout, so it drags no entry into context; a command with no such token matches nothing at all. The verb is never read, so `grep pattern src/Billing/Totals.php` fires the rules for that file just as `vim` does — you are about to look at it either way.

Four kinds of token are refused before anything on disk is consulted, because each one can resolve outside the project you opened: anything containing a `..` component, an absolute path that is not under the project directory, anything containing a backslash — an escape character here, a path separator on Windows — and any token whose name, or any directory on the way to it, is a symbolic link. A rule fires for the files your project contains, and for nothing else.

