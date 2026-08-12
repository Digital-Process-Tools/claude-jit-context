# Security Policy

## Supported Versions

Only the latest minor version receives security updates.

| Version | Supported          |
| ------- | ------------------ |
| 0.3.x   | :white_check_mark: |
| < 0.3   | :x:                |

## Trust Model

These hooks run with your full shell privileges, like any other Claude Code hook.

What they do: read `.md` and `.tsv` files under `.claude/jit-context/`, read the JSON that
Claude Code pipes to them on stdin, write a timing log under
`.claude/jit-context/.discovery/logs/`, and write session marker files under
`.claude/jit-context/.discovery/state/`.

What they never do: make network requests, execute anything from a rule file, or write
outside those two locations. A rule file is injected as _text_; it is never evaluated.

Two things worth knowing:

- **Rule content becomes model context.** Anyone who can write to `.claude/jit-context/` can
  put text in front of your agent on the next matching prompt. Treat that directory with
  the same review discipline as `CLAUDE.md` — in practice, review rule files in pull
  requests like any other code.
- **`block` mode is a guardrail, not a security boundary.** It stops a tool call that
  matches a pattern. It is there to catch mistakes, not to contain an adversary.

Session markers live in `.claude/jit-context/.discovery/state/`, named for the
`session_id` of the session that wrote them. They hold entry filenames, never content. Up
to 0.3.0 they were `/tmp/claude-*-shown-$PPID.txt`, which was world-readable on a shared
machine and keyed on a pid the OS recycles — two unrelated sessions could suppress each
other entries, including a refusal notice. They are no longer in a shared directory, and
nothing this plugin runs deletes a file outside the project it was invoked for.

## Reporting a Vulnerability

**Do not open public GitHub issues for security vulnerabilities.**

Email **fdavid@digitalprocesstools.com** with:

- A description of the issue
- Steps to reproduce
- Affected version (see `.claude-plugin/plugin.json`)
- Impact assessment if known

You can expect an acknowledgment within 7 days. We will work with you to understand and
resolve the issue, and credit you in the release notes if desired.
