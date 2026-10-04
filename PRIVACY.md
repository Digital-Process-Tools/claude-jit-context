# Privacy

JIT Context runs entirely on your machine. It has no server, no account and no telemetry,
and it sends nothing over the network: none of its scripts opens a connection.

## What it reads

- The prompt you type, the tool call about to run, and the path of the file being touched,
  as Claude Code hands them to the hooks. They are matched against your own entries and not
  kept beyond what the log below records.
- The entries in your project's `.claude/jit-context/` directory, and its `config.env`.

Outside the project, it reads only the plugin's own files, with two exceptions:

- On every prompt and tool call, the hooks ask git for the top of the repository you are
  standing in and of the project Claude Code opened (`git rev-parse --show-toplevel`). When
  the two differ, they tell the model both paths, so it does not edit the wrong worktree.
  This reads git's own metadata, nothing else, and is not kept.
- `/jit-context:doctor`, run by hand: to say which copy of the plugin is active, it reads
  `~/.claude/settings.json` and lists the plugin's own copies in Claude Code's plugin
  cache. It prints what it finds to you and keeps nothing.

## What it writes

**In every project, opted in or not:** each prompt and tool-call hook creates a few scratch
files in your temporary directory (`$TMPDIR`, or `/tmp`), named `claude-jit-...`, readable
by you only, and deletes them when the hook exits. They hold the hook's own working data and
the log line described below, the start of your prompt included, **even in a project that has
not opted in**; there the line is then discarded instead of appended to a log. A hook that is
killed can leave one behind; your system's temporary-directory cleanup removes it.

**Only in a project that has opted in**, by having a `.claude/jit-context/` directory, and
only inside its `.claude/jit-context/.discovery/`:

- `logs/hooks.log`: one line per prompt or tool call, whether or not an entry matched, with
  the time, the hook, which entries fired and on which word or path, and part of what it was
  given:
  - for a prompt, its first 80 bytes;
  - for a tool call, up to 120 bytes made of the file path and of every word in the command
    that contains a `/` (paths and URLs), wherever it sits in the command, lowercased;
  - for a file being touched, up to 200 bytes of the paths involved.

  The words that recur in your prompts with no entry behind them are reported from this
  log. So the start of a prompt, and a URL or path anywhere in a command, can end up in this
  file on your disk, a secret included if it was pasted there (a token in a URL, say). The
  log rotates at 20 MB by default, checked when a session starts, and keeps one previous
  copy, `hooks.log.1`. The size is set by `JIT_CONTEXT_LOG_MAX_BYTES` in `config.env`.
- `state/`: small per-session markers, so an entry is shown once per session. Most are
  removed after seven days, at the start of a session; the `bytes-shown-*` markers (entry
  names and sizes) are currently not, and accumulate until you delete them (#469).

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
