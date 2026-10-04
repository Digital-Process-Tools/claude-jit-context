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

**In every project, opted in or not:** each prompt and tool-call hook creates a few scratch
files in your temporary directory (`$TMPDIR`, or `/tmp`), named `claude-jit-...`, and deletes
them when the hook exits. They hold the hook's own working data and, in an opted-in project,
the log line below before it is appended to the log. A hook killed outright can leave one
behind; your system's temporary-directory cleanup removes it.

**Only in a project that has opted in**, by having a `.claude/jit-context/` directory, and
only inside its `.claude/jit-context/.discovery/`:

- `logs/hooks.log`: one line per hook run, whether or not an entry matched, with the time,
  the hook, which entries fired and on which word or path, and the start of what it was
  given: the first 80 bytes of the prompt, or of a tool call the first 120 bytes of its
  command or the first 200 bytes of its file path. The words that recur in your prompts
  with no entry behind them are reported from this log. So anything you type at the very
  start of a prompt, a pasted secret included, can end up in this file on your disk. The
  log rotates at 20 MB by default and keeps one previous copy, `hooks.log.1`. The size is
  set by `JIT_CONTEXT_LOG_MAX_BYTES` in `config.env`.
- `state/`: small per-session markers, so an entry is shown once per session. Markers
  older than seven days are removed at the start of the next session.

Delete `.claude/jit-context/.discovery/` at any time; it holds no configuration, only these
records, and is recreated as needed.

The commands you run yourself also write where you point them: `/jit-context:init` creates
your first entries under `.claude/jit-context/`, and the index rebuild writes its
`00-index.tsv` files there.

## What it does not do

It does not look for names, emails or addresses, it has no connectors, and it does not
send, upload or share anything. Nothing it records leaves your machine unless you copy or
commit it yourself; this repository's own `.gitignore` excludes `.discovery/`, and yours
should too.
