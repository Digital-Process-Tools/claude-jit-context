# jit-context

Project knowledge that loads only when needed. Rules, conventions and domain notes are
matched against the prompt, the file being touched, or the tool being run -- and injected
just in time instead of sitting in context all session.

Every team has a vocabulary and a set of hard-won conventions that normally live in
people's heads, or in a rules file that grows until nobody reads it end to end. jit-context
keeps that knowledge on disk instead, split across three dimensions, and shows an agent only
the piece that applies to what it is doing right now:

- **paths** -- a rule tied to a file or a directory. Fires when that path is opened.
- **tools** -- a rule tied to a command shape. Fires when that command is about to run.
- **vocabulary** -- a rule tied to a word or phrase. Fires when the prompt mentions it.

Nothing loads speculatively, and nothing stays resident once the moment has passed. A
session that never touches billing code never pays for the billing conventions; a session
that opens a migration gets the migration note exactly when it needs it.

## Install

```
/plugin marketplace add Digital-Process-Tools/claude-marketplace
/plugin install jit-context@dpt-plugins
```

## Commands

- `/jit-context:doctor` -- is any of this running at all, and against which tree?
- `/jit-context:init` -- seed a project with the three dimensions and one starter entry.
- `/jit-context:stats` -- what fired this session, on what word, and what it cost.
- `/jit-context:vocabulary` -- write a vocabulary entry that actually matches.

## Full documentation

The complete README -- install options, how matching works, writing your own rules, and
the token-cost receipt -- lives on the default branch:
<https://github.com/Digital-Process-Tools/claude-jit-context/blob/main/README.md>.
