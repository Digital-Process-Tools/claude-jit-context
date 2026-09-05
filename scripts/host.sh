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
#                        watched Codex fire its own INJECT-ONLY hooks, which was never
#                        evidence about this plugin's harder contract. codex is
#                        OBSERVED here on #288's own runs against codex-cli 0.150.1:
#                        PreToolUse fired, the payload carried tool_name and
#                        tool_input under those names, and a {"decision":"block"}
#                        stopped a real command from running.
#   6  inject_envelope   the shape identifier a SessionStart/UserPromptSubmit/
#                        PostToolUse inject must take on this host, or UNKNOWN
#   7  refusal_envelope  the shape identifier a PreToolUse refusal must take,
#                        "unsupported" if the host has no refusal contract at all, or
#                        "refusal-not-established" -- a host we have not watched
#                        refuse a call, which must never be read as either of the
#                        other two. See jit_host_refusal_state() below.
#   8  tool_aliases      #364: comma-separated `hostname=canon1;canon2` pairs mapping
#                        this host's OWN tool_name value onto the canonical vocabulary
#                        every entry's `tool:` field is written against (Claude Code's
#                        own names -- Edit, Write, Bash, ... -- see below for why that
#                        one is canonical). "" when the host's own names already ARE
#                        the canonical set. Semicolon, not the column-2/4 comma: this
#                        column's own VALUES are themselves a comma-joined list of
#                        pairs, so a second list nested inside one pair needs a third
#                        character or a rule's `Edit|Write` could never round-trip
#                        through it.
#
#                        DIRECTION: host name onto canonical, never the reverse. No
#                        entry, example, or template ever learns a second host's
#                        tool_name -- that is the whole reason this is a column on the
#                        registry rather than the alternation-stopgap #364 refused
#                        (`tool: Edit|Write|apply_patch` in every block rule anyone
#                        ever writes, in files this project does not control, that
#                        degrades silently the day a fourth host arrives with a fifth
#                        name).
#
#                        LOOKUP IS HOST-AGNOSTIC ON PURPOSE, not gated behind
#                        jit_host_detect(). The comment above already establishes
#                        detection is BEST-EFFORT and non-load-bearing -- a genuine
#                        Codex hook launched from inside a Claude Code shell inherits
#                        CLAUDE_CODE_ENTRYPOINT and misdetects as claude-code, and a
#                        standalone Codex hook carries no signature at all and
#                        misdetects as unknown. $JIT_HOST can be "codex" only when a
#                        caller passes that literal by hand (a test, or a future
#                        signature this file does not have yet) -- it is never the
#                        live value during a real Codex PreToolUse call. Gating
#                        `apply_patch`'s normalisation behind a correct "codex"
#                        detection would make the REFUSAL contract depend on the one
#                        thing this file says must never be load-bearing, and would
#                        reproduce #364 exactly on the misdetected path. So
#                        jit_all_tool_aliases() (below) unions every row's column 8
#                        rather than reading one host's row: `apply_patch` is a name
#                        no other host uses for anything, so mapping it unconditionally
#                        costs nothing on claude-code or an unknown host and closes the
#                        gap on every Codex path, detected or not.
#
# Ordered most-specific-signature-first, same posture as remember's REGISTRY: a row
# with a real signature is tried before one with none, so an empty signature can never
# accidentally win a tie it was never meant to enter.
#
# codex carries NO signature_vars, and that is a measurement rather than an omission.
# The row previously claimed CODEX_SESSION_ID,CODEX_THREAD_ID, copied from remember's
# own CODEX Host instance. #288 captured the whole environment of a real Codex
# PreToolUse hook -- 54 variables -- and not one CODEX_ variable was among them, so
# that signature could never have fired. remember reached the same conclusion from the
# other side: those names reach a Codex *tool shell*, never the process that runs a
# hook, which is why its own detect_host() ended with zero production consumers.
#
# What #288 also captured is why detection here is BEST-EFFORT and must stay
# non-load-bearing: a Codex hook launched from inside a Claude Code shell inherits
# CLAUDE_CODE_ENTRYPOINT and CLAUDE_CODE_SESSION_ID from its parent, so
# jit_host_detect() answers "claude-code" for a genuine Codex hook. That is not a bug
# to fix by adding a cleverer signature -- one agent CLI launching another is the
# normal way this plugin gets exercised, and no environment variable survives it.
#
# It costs nothing on the wire, which is the point: #288 observed that Codex takes the
# SAME envelope Claude Code does, both directions. Same payload field NAMES
# (tool_name, tool_input.command), same {"decision":"block"}, same hookSpecificOutput.
# So the two rows carry identical envelope columns (5-7), tests/test-host-registry.sh
# asserts they stay identical, and a misdetection between them cannot change a byte
# emitted.
#
# #364 (Codex's own comment, third one) is the correction to a line that used to sit
# here claiming the two rows carry "identical contracts" outright: that was right about
# the field NAMES and wrong about the VALUES they carry. `tool_name` arrives under that
# exact name on both hosts and carries `apply_patch` on one and `Edit`/`Write` on the
# other for the identical user action -- a same-schema, different-vocabulary split this
# file conflated until a live Codex run reproduced it (the block never fired: the rule
# never got as far as deciding, because `apply_patch` matched no alternative in
# `tool: Edit|Write`). Column 8 exists because "same schema" was never "same
# vocabulary".
#
# gemini-cli carries no signature and no known variables at all: Gemini CLI documents
# none for command hooks, which remember's own registry notes is not a gap in what it
# records -- "it is what UNKNOWN already behaves like." It is also the design's real
# test (BeforeTool/AfterTool), and nothing in #288 speaks to it.
# codex's column 8 maps `apply_patch` to BOTH `Edit` and `Write`, not to whichever one
# guesses right. Codex has one file-writing tool where Claude Code has two, so no
# mapping recovers the distinction a rule author drew by writing `tool: Write` versus
# `tool: Edit` -- mapping to one guesses wrong on the other half of Codex's own calls,
# and mapping to neither reproduces #364. Mapping to both over-refuses a `mode: block`
# rule that named only one of the two (it now also fires on a Codex CREATE if it said
# `tool: Write` and meant only an edit-in-place, or on a Codex EDIT if it said
# `tool: Edit` and meant only a fresh file). Over-refusing is the safe direction and
# the sibling rule one file over (tools/00-manual/no-shell-writes-to-the-index.md)
# already takes the identical trade for its own pattern -- naming three write forms
# broader than the one the author had in mind, rather than a narrower rule a real
# write slips past. An injecting (non-block) rule is unaffected either way: it was
# always going to fire on the wider of the two sets it named.
JIT_HOST_REGISTRY='
claude-code|CLAUDE_CODE_ENTRYPOINT,CLAUDE_CODE_SESSION_ID|CLAUDE_PROJECT_DIR|CLAUDE_PLUGIN_ROOT|OBSERVED|claude-hookSpecificOutput|claude-decision-block|
codex||CLAUDE_PROJECT_DIR|PLUGIN_ROOT,CLAUDE_PLUGIN_ROOT|OBSERVED|claude-hookSpecificOutput|claude-decision-block|apply_patch=Edit;Write
gemini-cli||||UNKNOWN|UNKNOWN|refusal-not-established|
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
      "$want"'|'*)
        printf '%s\n' "$line"
        return 0
        ;;
    esac
  done << JIT_HOST_ROW_EOF
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
  done << JIT_HOST_DETECT_EOF
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
  row=$(jit_host_row "$1") || {
    printf 'UNKNOWN\n'
    return 0
  }
  IFS='|' read -r _ _ _ _ state _ _ _ <<< "$row"
  printf '%s\n' "${state:-UNKNOWN}"
}

# jit_host_inject_envelope NAME -- the inject shape identifier, or UNKNOWN.
jit_host_inject_envelope() {
  local row
  row=$(jit_host_row "$1") || {
    printf 'UNKNOWN\n'
    return 0
  }
  IFS='|' read -r _ _ _ _ _ inject _ _ <<< "$row"
  printf '%s\n' "${inject:-UNKNOWN}"
}

# jit_host_refusal_state NAME -- the third state, enforced here rather than left to
# every caller to remember. Three answers, never two:
#   claude-decision-block      this plugin has watched this host honour a PreToolUse
#                              {"decision":"block"} refusal
#   unsupported                this host has been watched NOT support a refusal at all
#                              (no row is this today -- a real negative result, not
#                              yet observed for any host)
#   hook-not-trusted           the host has the contract and the plugin declares the
#                              hook, and the host is DECLINING TO RUN IT. Observed for
#                              #288: Codex keys a trusted_hash per hook in its
#                              config.toml, and a hook with no entry is silently
#                              skipped -- no warning, no non-zero exit, no transcript
#                              line, the tool call simply proceeds. This is neither of
#                              the two above: "unsupported" says the host cannot block,
#                              "refusal-not-established" says nobody checked, and this
#                              says the host can and we asked and it did not. No ROW
#                              carries it -- it is not a property of a host, it is a
#                              property of one install -- but jit_host_refusal_honoured()
#                              below must answer "no" for it, which is the whole reason
#                              it is named rather than folded into either neighbour.
#   refusal-not-established    every other case: an unrecognised NAME, a row with
#                              nothing in its 7th column, or a row whose state is not
#                              OBSERVED. This is NOT "unsupported" -- it is "nobody has
#                              checked", and treating the two as one answer is the
#                              exact defect #252 opens with: a `forbid:` rule silently
#                              reading as enforced on a host that was never watched
#                              refuse anything.
jit_host_refusal_state() {
  local name="${1:-}" row refusal
  [ -n "$name" ] || {
    printf 'refusal-not-established\n'
    return 0
  }
  row=$(jit_host_row "$name") || {
    printf 'refusal-not-established\n'
    return 0
  }
  IFS='|' read -r _ _ _ _ _ _ refusal _ <<< "$row"
  printf '%s\n' "${refusal:-refusal-not-established}"
}

# jit_host_refusal_state_for_envelope ENVELOPE -- the identity function over refusal
# envelope identifiers, with an unrecognised value normalised to the safe third state.
# It exists so a caller holding an envelope identifier that did NOT come from a
# registry row -- "hook-not-trusted", derived per install rather than per host -- runs
# through the same recognition every row value does, instead of being compared against
# string literals at each call site.
jit_host_refusal_state_for_envelope() {
  case "${1:-}" in
    claude-decision-block | unsupported | hook-not-trusted) printf '%s\n' "$1" ;;
    *) printf 'refusal-not-established\n' ;;
  esac
}

# jit_host_refusal_honoured ENVELOPE -- "yes" only when a refusal emitted in this shape
# has been watched stop a real call. Everything else is "no", and the three ways of
# being "no" are deliberately not collapsed by the caller: this function is the single
# place that decides, so a hook can never accidentally treat "nobody checked" or "the
# host declined to run us" as permission to emit a block that will be ignored.
jit_host_refusal_honoured() {
  case "$(jit_host_refusal_state_for_envelope "${1:-}")" in
    claude-decision-block) printf 'yes\n' ;;
    *) printf 'no\n' ;;
  esac
}

# jit_host_tool_aliases NAME -- column 8, raw, for one named row. "" for a row with
# nothing in that column, an unrecognised NAME, or the empty string. Exists mainly so
# tests and jit-doctor.sh can ask what one row's own column says; the hooks never call
# this one (see jit_all_tool_aliases() below for why).
jit_host_tool_aliases() {
  local row aliases
  row=$(jit_host_row "${1:-}") || {
    printf '\n'
    return 0
  }
  IFS='|' read -r _ _ _ _ _ _ _ aliases <<< "$row"
  printf '%s\n' "${aliases:-}"
}

# jit_all_tool_aliases -- every row's column 8, concatenated with commas, empties
# dropped. This is what a hook actually sources (see #364's own comment on column 8,
# above the registry, for why the lookup is not gated behind jit_host_detect()): a
# host-agnostic table it can hand jit_canonical_tool() unconditionally, on every call,
# regardless of which host this process thinks it is running under.
jit_all_tool_aliases() {
  local line aliases all="" sep=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    aliases="${line##*|}"
    [ -n "$aliases" ] || continue
    all="$all$sep$aliases"
    sep=","
  done <<< "$JIT_HOST_REGISTRY"
  printf '%s\n' "$all"
}

# jit_canonical_tool ALIASES RAW -- RAW's canonical name(s), space-separated, or RAW
# itself unchanged when ALIASES names no mapping for it (the identity case every host
# whose own vocabulary already IS canonical takes, and the safe default for a RAW
# nobody has written an alias for yet). ALIASES is jit_all_tool_aliases()'s own output
# shape: comma-joined `key=v1;v2` pairs. Pure function, no state, no I/O -- callable
# from a plain bash context (post-tool-hook.sh's own tool-name gate) without sourcing
# anything beyond this file.
#
# One raw name can map to SEVERAL canonical ones (codex's own `apply_patch=Edit;Write`,
# see the registry comment above for why mapping to both rather than choosing one is
# the deliberate, over-refusing direction) -- the semicolon-joined right-hand side
# becomes a space-joined result here so a caller can `for` over it with a plain
# word-split, the same shape jit_scan_layers() already hands back for its own
# space-separated layer list.
jit_canonical_tool() {
  local aliases="${1:-}" raw="${2:-}" entry key vals
  [ -n "$aliases" ] && [ -n "$raw" ] || {
    printf '%s\n' "$raw"
    return 0
  }
  local old_ifs="$IFS"
  IFS=','
  for entry in $aliases; do
    IFS="$old_ifs"
    key="${entry%%=*}"
    [ "$key" = "$raw" ] || continue
    vals="${entry#*=}"
    printf '%s\n' "${vals//;/ }"
    return 0
  done
  IFS="$old_ifs"
  printf '%s\n' "$raw"
}
