#!/bin/bash
# claude-jit-context — SessionStart hook
# Clears all "once" markers so dynamic rules fire fresh each session.
# Self-contained: the claude-jit-context system creates the markers, this cleans them.
# Patterns: vocab (pre-prompt), path (pre-path), rule (pre-tool).

rm -f /tmp/claude-vocab-shown-$PPID.txt
rm -f /tmp/claude-path-shown-$PPID.txt
rm -f /tmp/claude-hook-log-*.tmp
echo '{}'
