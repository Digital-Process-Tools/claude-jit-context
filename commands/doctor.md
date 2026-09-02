---
description: Diagnose claude-jit-context -- is any of this running at all, and against which tree?
allowed-tools: Bash
---

Run the diagnostic and relay its output verbatim:

```bash
IFS=' ' read -r -a jit_doctor_args <<< "${ARGUMENTS:-}"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/jit-doctor.sh" ${jit_doctor_args[@]+"${jit_doctor_args[@]}"}
```

`${CLAUDE_PLUGIN_ROOT}` is what makes this reachable without a version number: the only
other way to run this tool is `bash ~/.claude/plugins/cache/dpt-plugins/claude-jit-context/<version>/scripts/jit-doctor.sh`,
and that path changes on every plugin update (#202). `hooks/hooks.json` already resolves
every hook the same way; this is the same resolution, for the one diagnostic you reach for
when you suspect nothing is firing and do not yet know why.

`jit-doctor.sh` parses `--base <tree>` as two separate words (the `--base)` arm in its own
argument loop), so `$ARGUMENTS` is genuinely meant to carry more than one shell word here --
a plain `"$ARGUMENTS"` would hand the script one combined argument and break `--base`. The
array above makes that splitting explicit instead of leaning on bash's own
unquoted-expansion word-splitting, which also glob-expands: a typed value containing `*` or
`?` used to be matched against whatever files sat in the current directory and spliced in
as extra arguments, silently and differently on every machine (#278). `read -a` still
splits on spaces; it never globs.

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
