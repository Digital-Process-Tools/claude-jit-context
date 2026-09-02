---
description: Seed .claude/jit-context with one live entry that says how to write the next one
allowed-tools: Bash
---

Run the seeder and relay its output verbatim:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/jit-init.sh" $ARGUMENTS
```

`${CLAUDE_PLUGIN_ROOT}` is the same resolution `commands/doctor.md` uses, for the same
reason (#202): after a marketplace install there is no other reachable path to
`jit-init.sh` from a user's own shell.

`$ARGUMENTS` passes through `--base <project>/.claude/jit-context` unchanged, so this
seeds another project exactly as running the script directly would.

A second run over an already-seeded project **refuses rather than overwrites**, exits `1`,
and names the file it left alone -- a copy you have since edited is not ours to replace.
Relay that refusal verbatim too; it is not a failure of this command.
