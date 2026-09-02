---
description: Seed .claude/jit-context with one live entry that says how to write the next one
allowed-tools: Bash
---

Run the seeder and relay its output verbatim:

```bash
IFS=' ' read -r -a jit_init_args <<< "${ARGUMENTS:-}"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/jit-init.sh" ${jit_init_args[@]+"${jit_init_args[@]}"}
```

`${CLAUDE_PLUGIN_ROOT}` is the same resolution `commands/doctor.md` uses, for the same
reason (#202): after a marketplace install there is no other reachable path to
`jit-init.sh` from a user's own shell.

`jit-init.sh` parses `--base <project>/.claude/jit-context` as two separate words (the
`--base)` arm in its own argument loop), so `$ARGUMENTS` is genuinely meant to carry more
than one shell word here -- a plain `"$ARGUMENTS"` would hand the script one combined
argument and break `--base`. The array above makes that splitting explicit instead of
leaning on bash's own unquoted-expansion word-splitting, which also glob-expands: a typed
value containing `*` or `?` used to be matched against whatever files sat in the current
directory and spliced in as extra arguments, silently and differently on every machine
(#278). `read -a` still splits on spaces; it never globs.

A second run over an already-seeded project **refuses rather than overwrites**, exits `1`,
and names the file it left alone -- a copy you have since edited is not ours to replace.
Relay that refusal verbatim too; it is not a failure of this command.
