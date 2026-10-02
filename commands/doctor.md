---
description: Diagnose claude-jit-context -- is any of this running at all, and against which tree?
allowed-tools: Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/jit-doctor.sh:*)
---

Run the diagnostic and relay its output verbatim:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/jit-doctor.sh --arguments-string "${ARGUMENTS:-}"
```

**The whole typed `$ARGUMENTS` string is handed through one synthetic `--arguments-string`
flag, rather than split here in the command body (#439).** A bare `allowed-tools: Bash`
grants every shell command the directory holds as unrestricted access; narrowing it to one
script only works if the body's own first words are that exact script invocation. The
previous body wrapped the whole thing in an explicit `bash -c '...'` to force the `read -a`
splitting in #405 into a real bash regardless of what shell ran this fenced body -- but that
made the body's first word `bash -c`, not the script, so no grant could ever name just this
script. `jit-doctor.sh` already does its own flag parsing (`--base`'s own `case` arm); it
now does the splitting too, under the bash it always runs under, so the grant above can name
it directly.

`${CLAUDE_PLUGIN_ROOT}` is what makes this reachable without a version number: the only
other way to run this tool is `bash ~/.claude/plugins/cache/dpt-plugins/claude-jit-context/<version>/scripts/jit-doctor.sh`,
and that path changes on every plugin update (#202). `hooks/hooks.json` already resolves
every hook the same way; this is the same resolution, for the one diagnostic you reach for
when you suspect nothing is firing and do not yet know why.

`jit-doctor.sh` parses `--base <tree>` as two separate words (the `--base)` arm in its own
argument loop), so `$ARGUMENTS` is genuinely meant to carry more than one shell word here --
a plain `"$ARGUMENTS"` would hand the script one combined argument and break `--base`. The
body above passes the whole string as ONE quoted argument to `--arguments-string` precisely
so nothing splits or globs it before the script sees it; `jit-doctor.sh` then builds the
array itself with `read -a`, which splits on spaces and never globs. Quoting it here is what
keeps a typed value containing `*` or `?` from matching whatever files sat in the current
directory and splicing in as extra arguments, silently and differently on every machine
(#278).

Do not summarise away any line -- relay the report exactly as printed, including its blank
lines and its section headers. Three outcomes, and only the report itself carries which one
this run reached:

- **exit 0, "nothing inert"** -- every ADVISORY finding still lands in the output; read them,
  do not drop them because the run was clean.
- **exit 1** -- a layer holds `.md` entries and no `00-index.tsv` beside them, so the matcher
  can never load them. This is a defect in the tree, not in the diagnostic.
- **exit 2, `SKIPPED`** -- the tree could not be evaluated at all. This is not a clean
  result and must never be relayed as one; the reason is named on stderr.

The line worth reading before any other: **`which copy runs`**, under `hooks`. `cannot tell`
is a real, first-class answer -- not a failure of the diagnostic -- because Claude Code
merges settings from places a script cannot enumerate. Never restate `cannot tell` as
"nothing is registered"; those are different claims and the report says so.

If the report names more than one plugin cache copy under `plugin copy`, that is #189's own
finding: which one loads is not decidable from here, and the diagnostic says so rather than
guessing. Do not pick one and report it as the answer.
