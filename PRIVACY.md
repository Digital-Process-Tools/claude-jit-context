# Privacy

JIT Context runs entirely on your machine. It has no server, no account and no telemetry,
and it sends nothing over the network: none of its scripts opens a connection.

## What it reads

- The prompt you type, the tool call about to run, and the path of the file being touched,
  as Claude Code hands them to the hooks. They are matched against your own entries and not
  kept beyond what the log below records.
- The entries in your project's `.claude/jit-context/` directory, and its `config.env`.

Nothing outside the project is read, apart from the plugin's own files. The one exception
is `/jit-context:doctor`, run by hand: to say which copy of the plugin is active, it reads
`~/.claude/settings.json` and lists the plugin's own copies in Claude Code's plugin cache.
It prints what it finds to you and keeps nothing.

## What it writes

Only inside the project's `.claude/jit-context/.discovery/` directory, and only once the
project has opted in by having a `.claude/jit-context/` directory at all. In any other
project the plugin creates nothing and logs nothing.

- `logs/hooks.log`: one line per hook run, with the time, the hook, which entries fired, on
  which word or path, and their size. The words that recur in your prompts with no entry
  behind them are reported from this log, so a word you typed can appear in it. The log
  rotates at 20 MB by default and keeps one previous copy, `hooks.log.1`. The size is set by
  `JIT_CONTEXT_LOG_MAX_BYTES` in `config.env`.
- `state/`: small per-session markers, so an entry is shown once per session. Markers
  older than seven days are removed at the start of the next session.

Delete `.claude/jit-context/.discovery/` at any time; it holds no configuration, only these
records, and is recreated as needed.

## What it does not do

It does not look for names, emails or addresses, it has no connectors, and it does not
send, upload or share anything. Nothing it records leaves your machine unless you copy or
commit it yourself; this repository's own `.gitignore` excludes `.discovery/`, and yours
should too.
