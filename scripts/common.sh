#!/bin/bash
# Shared functions for claude-jit-context hooks and pipeline scripts.
# Source this at the top of every script: source "$(dirname "$0")/common.sh"

_ms() { perl -MTime::HiRes -e 'printf("%.0f\n",Time::HiRes::time()*1000)'; }

JIT_BASE="${CLAUDE_PROJECT_DIR:-.}/.claude/jit-context"

# Optional per-project settings (DYNAMIC_RULES_MODULE_PREFIX, _KEYWORD_BLACKLIST,
# _VOCAB_PATHS). Kept beside the content it configures, not in the plugin.
# shellcheck source=/dev/null
[ -f "$JIT_BASE/config.env" ] && . "$JIT_BASE/config.env"
LOG_DIR="$JIT_BASE/.discovery/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/hooks.log"

# Timestamp with ms precision (single perl call, ~11ms)
_ts() { perl -MTime::HiRes -MPOSIX -e 'my $t=Time::HiRes::time(); printf("%s.%03d\n", strftime("%H:%M:%S",localtime($t)), ($t*1000)%1000)'; }

# Pipeline log: _log "step" duration_ms "message"  → [HH:MM:SS.mmm] step 42ms | message
_log() {
  local line="$1 ${2}ms | $3"
  echo "[$(_ts)] $line" >> "$LOG_FILE"
  echo "$line"
}

# Hook log with timing + matches: _log_hook "pre-tool (Bash)" 42 "tool:git-push.md(git push)"
_log_hook() {
  local hook="$1"
  local ms="$2"
  local matches="${3:-(none)}"
  echo "[$(_ts)] $hook ${ms}ms | $matches" >> "$LOG_FILE"
}
