#!/bin/bash
# scripts/host.sh -- the host descriptor registry (#252).
#
# `claude-jit-context` runs under Claude Code today. This is the table a second and
# third host become entries in, instead of a second and third fork of every hook -- the
# shape #252 asked for, sized against the `remember` plugin's own prior art rather than
# invented from scratch: `pipeline/host.py` at 0.24.0 is a frozen four-field dataclass
# per host (name, plugin_root_vars, project_dir_vars, signature_vars) and its own
# docstring says outright it "is deliberately thin, and is not a host abstraction
# layer." This file is that shape in bash, sourced by common.sh -- and sourced means
# every failure path here obeys paths/00-manual/hooks.md exactly like the hooks it runs
# inside of: never fail hard, an unrecognised host degrades to a named third state,
# never a guess.
#
# One field is new relative to `remember`, for the reason #252 opens with: that plugin
# only ever injects. This one also REFUSES a tool call ("decision":"block"), so a host
# whose refusal contract nobody has watched fire is exactly the silent-degrade this
# plugin exists to prevent elsewhere -- a `forbid:` rule that reads as enforced forever
# while doing nothing. So every row below carries an ENVELOPE contract (what an inject
# looks like, what a refusal looks like, whether refusal exists at all) and a STATE
# distinguishing "claude-jit-context has been run here and this is what was seen" from
# "this row exists so a fourth host is a table entry, not a guess dressed as one."
#
# Bash 3.2 (macOS, and Git Bash) has no associative arrays -- the same constraint
# jit_scan_symlinks() in common.sh already works under -- so this is a flat,
# pipe-delimited table rather than a dict-of-dicts, walked with a `while read` loop
# rather than indexed by key.
#
# Columns, in order:
#   1  name              the host's own name for itself
#   2  signature_vars    comma-separated env var names; ANY present identifies the
#                        host. Never plugin_root_var or project_dir_var: Codex sets
#                        CLAUDE_PLUGIN_ROOT too, as a compatibility alias it can
#                        withdraw (remember's own host.py docstring), so a variable a
#                        second host also sets can never BE the signature that tells
#                        them apart.
#   3  project_dir_var   the var this host sets for the project root, or "" if none
#                        is documented
#   4  plugin_root_var   the var(s) this host sets for the plugin install dir
#                        (comma-separated, precedence order), or ""
#   5  state             OBSERVED or UNKNOWN -- has claude-jit-context ITSELF been run
#                        under this host and watched fire. Never set to OBSERVED on
#                        the strength of another plugin's observation: remember 0.24.0
#                        watched Codex fire its own inject-only hooks against a real
#                        codex-cli 0.150.1 install, and that is real evidence the
#                        signature/var columns below are grounded rather than
#                        invented -- it is not evidence about THIS plugin's harder
#                        contract, the PreToolUse refusal, which remember never uses
#                        and Codex has not been watched honour for us.
#   6  inject_envelope   the shape identifier a SessionStart/UserPromptSubmit/
#                        PostToolUse inject must take on this host, or UNKNOWN
#   7  refusal_envelope  the shape identifier a PreToolUse refusal must take,
#                        "unsupported" if the host has no refusal contract at all, or
#                        "refusal-not-established" -- a host we have not watched
#                        refuse a call, which must never be read as either of the
#                        other two. See jit_host_refusal_state() below.
#
# Ordered most-specific-signature-first, same posture as remember's REGISTRY: a row
# with a real signature is tried before one with none, so an empty signature can never
# accidentally win a tie it was never meant to enter.
#
# codex's signature_vars, project_dir_var and plugin_root_var are copied verbatim from
# remember's own CODEX Host instance (pipeline/host.py, 0.24.0) -- CODEX_SESSION_ID and
# CODEX_THREAD_ID are, in that file's own words, "what a live codex exec process
# actually exports on every run, verified against codex-cli 0.150.1". gemini-cli
# carries no signature and no known variables at all: Gemini CLI documents none for
# command hooks, which remember's own registry notes is not a gap in what it records --
# "it is what UNKNOWN already behaves like."
JIT_HOST_REGISTRY='
claude-code|CLAUDE_CODE_ENTRYPOINT,CLAUDE_CODE_SESSION_ID|CLAUDE_PROJECT_DIR|CLAUDE_PLUGIN_ROOT|OBSERVED|claude-hookSpecificOutput|claude-decision-block
codex|CODEX_SESSION_ID,CODEX_THREAD_ID|CLAUDE_PROJECT_DIR|PLUGIN_ROOT,CLAUDE_PLUGIN_ROOT|UNKNOWN|UNKNOWN|refusal-not-established
gemini-cli||||UNKNOWN|UNKNOWN|refusal-not-established
'

# jit_host_row NAME -- echoes NAME's whole pipe-delimited row on stdout and returns 0,
# or prints nothing and returns 1 when NAME matches no row. NAME is always a value this
# file itself produced (jit_host_detect's own output, or a literal in a caller/test),
# never attacker-controlled input, so no escaping is done on it here.
jit_host_row() {
  local want="$1" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$want"'|'*) printf '%s\n' "$line"; return 0 ;;
    esac
  done <<JIT_HOST_ROW_EOF
$JIT_HOST_REGISTRY
JIT_HOST_ROW_EOF
  return 1
}

# jit_host_detect -- identifies the hosting CLI from its own environment, mirroring
# remember's detect_host(). Always prints exactly one line and always returns 0: a host
# nobody has described yet is a normal state here, never a failure, the same posture
# every other lookup in this file takes. `${!sig:-}` is indirect expansion, supported
# since bash 2.0 -- no associative array and no eval needed to test a variable named by
# a string.
jit_host_detect() {
  local name sigs sig old_ifs
  while IFS='|' read -r name sigs _ _ _ _ _; do
    [ -n "$name" ] || continue
    [ -n "$sigs" ] || continue
    old_ifs="$IFS"
    IFS=','
    for sig in $sigs; do
      IFS="$old_ifs"
      if [ -n "${!sig:-}" ]; then
        printf '%s\n' "$name"
        return 0
      fi
    done
    IFS="$old_ifs"
  done <<JIT_HOST_DETECT_EOF
$JIT_HOST_REGISTRY
JIT_HOST_DETECT_EOF
  printf 'unknown\n'
  return 0
}

# jit_host_state NAME -- OBSERVED or UNKNOWN. A NAME matching no row (including
# "unknown", jit_host_detect's own miss value) is UNKNOWN: absence from the registry
# and absence of observation read the same way here on purpose.
jit_host_state() {
  local row
  row=$(jit_host_row "$1") || { printf 'UNKNOWN\n'; return 0; }
  IFS='|' read -r _ _ _ _ state _ _ <<<"$row"
  printf '%s\n' "${state:-UNKNOWN}"
}

# jit_host_inject_envelope NAME -- the inject shape identifier, or UNKNOWN.
jit_host_inject_envelope() {
  local row
  row=$(jit_host_row "$1") || { printf 'UNKNOWN\n'; return 0; }
  IFS='|' read -r _ _ _ _ _ inject _ <<<"$row"
  printf '%s\n' "${inject:-UNKNOWN}"
}

# jit_host_refusal_state NAME -- the third state, enforced here rather than left to
# every caller to remember. Three answers, never two:
#   claude-decision-block      this plugin has watched this host honour a PreToolUse
#                              {"decision":"block"} refusal
#   unsupported                this host has been watched NOT support a refusal at all
#                              (no row is this today -- a real negative result, not
#                              yet observed for any host)
#   refusal-not-established    every other case: an unrecognised NAME, a row with
#                              nothing in its 7th column, or a row whose state is not
#                              OBSERVED. This is NOT "unsupported" -- it is "nobody has
#                              checked", and treating the two as one answer is the
#                              exact defect #252 opens with: a `forbid:` rule silently
#                              reading as enforced on a host that was never watched
#                              refuse anything.
jit_host_refusal_state() {
  local name="${1:-}" row refusal
  [ -n "$name" ] || { printf 'refusal-not-established\n'; return 0; }
  row=$(jit_host_row "$name") || { printf 'refusal-not-established\n'; return 0; }
  IFS='|' read -r _ _ _ _ _ _ refusal <<<"$row"
  printf '%s\n' "${refusal:-refusal-not-established}"
}
