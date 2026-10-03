#!/bin/bash
# jit-context -- "which entries does this text call for?", answerable from outside
# a session (#205).
#
# A headless run (`claude -p`) sends exactly one prompt, usually built from paths rather
# than prose, so the vocabulary dimension matches almost nothing on the runs that would
# benefit most from it. The run usually DOES have prose -- the issue or ticket it was
# launched for -- just not in a form UserPromptSubmit ever sees. This is the supported way
# to ask the plugin what that prose calls for, without a caller resolving the version-
# numbered plugin cache path or hand-building a hook payload itself.
#
# Usage:
#   bash scripts/jit-match.sh --base DIR --text "the new component does not autocomplete"
#   printf '%s' "$TICKET_BODY" | bash scripts/jit-match.sh --base DIR
#   bash scripts/jit-match.sh --base DIR --text "..." --format json --summary --limit 3
#
# --base must be a `<project>/.claude/jit-context` path (default: ./.claude/jit-context,
# the tree you are standing in -- same convention as jit-dry-run.sh, and for the same
# reason: JIT_BASE resolves against $CLAUDE_PROJECT_DIR, never the current directory, so
# this has to point AT a project rather than assume it is standing inside one).
#
# --text is the prose to match. Omit it to read stdin instead -- an issue body is often
# long enough that a caller would rather pipe it than quote it.
#
# --format text (default) prints one block per matched entry, human-readable. --format
# json prints one JSON object with `count`, `dropped`, a `matches` array of
# {"file","keywords","mode","text"}, and an `unverifiable` array of the same shape minus
# `mode` -- no jq, no Python: hand-built by the same awk that reads the hook's own output.
# --summary forces the project default to `summary` for this call only (an entry pinned
# `inject: full` still renders full -- the same override JIT_CONTEXT_INJECT=summary gets
# in config.env, reachable per call instead of per project). --limit N keeps the first N
# VERIFIED matched entries and REPORTS what it dropped, by name -- a silent top-N reads as
# "nothing else applied" (#205's own words for why this exists).
#
# --- Why a match can come back "unverifiable" instead of counted ------------------------
#
# .claude/jit-context/ is attacker-controlled input (paths/00-manual/hooks.md). Until
# #219, the hook's own output joined matched entries with a literal "\n---\n# Vocabulary:
# " text boundary that an entry own author-controlled body could legitimately contain --
# so the splitter could not always tell a genuine join from the same bytes sitting inside
# one entry, and a crafted entry could make this tool print a fabricated match with an
# attacker-chosen file name and keyword list. #219 closed that class at the source: the
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  JIT_BASE="$CLAUDE_PROJECT_DIR/.claude/jit-context"
else
  JIT_BASE="$(pwd)/.claude/jit-context"
fi
export JIT_BASE
JIT_HOST="unknown"
JIT_HOST_REFUSAL_STATE="refusal-not-established"
JIT_TOOL_ALIASES=""
JIT_HOST_REGISTRY='
claude-code|CLAUDE_CODE_ENTRYPOINT,CLAUDE_CODE_SESSION_ID|CLAUDE_PROJECT_DIR|CLAUDE_PLUGIN_ROOT|OBSERVED|claude-hookSpecificOutput|claude-decision-block|
codex||CLAUDE_PROJECT_DIR|PLUGIN_ROOT,CLAUDE_PLUGIN_ROOT|OBSERVED|claude-hookSpecificOutput|claude-decision-block|apply_patch=Edit;Write
gemini-cli|GEMINI_SESSION_ID|GEMINI_PROJECT_DIR,CLAUDE_PROJECT_DIR||UNKNOWN|UNKNOWN|refusal-not-established|
'
jit_host_row() {
  local want="$1" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [[ "$line" == "$want|"* ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done <<< "$JIT_HOST_REGISTRY"
  return 1
}
jit_host_sig_set() {
  case "${1:-}" in
    CLAUDE_CODE_ENTRYPOINT) [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] ;;
    CLAUDE_CODE_SESSION_ID) [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] ;;
    GEMINI_SESSION_ID) [ -n "${GEMINI_SESSION_ID:-}" ] ;;
    *) return 1 ;;
  esac
}
jit_host_detect() {
  local name hostvars hostvar old_ifs
  while IFS='|' read -r name hostvars _ _ _ _ _; do
    [ -n "$name" ] || continue
    [ -n "$hostvars" ] || continue
    old_ifs="$IFS"
    IFS=','
    for hostvar in $hostvars; do
      IFS="$old_ifs"
      if jit_host_sig_set "$hostvar"; then
        printf '%s\n' "$name"
        return 0
      fi
    done
    IFS="$old_ifs"
  done <<< "$JIT_HOST_REGISTRY"
  printf 'unknown\n'
  return 0
}
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
JIT_HOST="$(jit_host_detect 2> /dev/null)" \
  && JIT_HOST_REFUSAL_STATE="$(jit_host_refusal_state "$JIT_HOST" 2> /dev/null)"
[ -n "$JIT_HOST" ] || JIT_HOST="unknown"
[ -n "$JIT_HOST_REFUSAL_STATE" ] || JIT_HOST_REFUSAL_STATE="refusal-not-established"
JIT_TOOL_ALIASES="$(jit_all_tool_aliases 2> /dev/null)"
[ -n "$JIT_TOOL_ALIASES" ] || JIT_TOOL_ALIASES=""
export JIT_HOST JIT_HOST_REFUSAL_STATE JIT_TOOL_ALIASES
export JIT_SYMLINKS=""
JIT_SYMLINKS_MAX=8192
export JIT_SYMLINKS_ALL=""
export JIT_NONFILES=""
export JIT_NONFILES_ALL=""
JIT_NONFILES_MAX=4096
JIT_NL="
"
jit_scan_symlinks() {
  local base="$1" f parent rel found=0
  JIT_SYMLINKS="$JIT_NL"
  JIT_SYMLINKS_ALL=""
  JIT_NONFILES="$JIT_NL"
  JIT_NONFILES_ALL=""
  if [ "${base%/*}" != "$base" ] && [ -L "${base%/*}" ]; then
    JIT_SYMLINKS="$JIT_SYMLINKS${base%/*}$JIT_NL$base$JIT_NL"
    found=1
  fi
  for f in "$base" "$base"/* "$base"/.* "$base"/*/* "$base"/*/.* "$base"/*/*/* "$base"/*/*/.*; do
    case "$f" in
      */. | */..) continue ;;
    esac
    if [ -L "$f" ]; then
      JIT_SYMLINKS="$JIT_SYMLINKS$f$JIT_NL"
      found=1
      if [ "${#JIT_SYMLINKS}" -gt "$JIT_SYMLINKS_MAX" ]; then
        JIT_SYMLINKS="$JIT_NL"
        JIT_SYMLINKS_ALL=1
        JIT_NONFILES="$JIT_NL"
        JIT_NONFILES_ALL=1
        export JIT_SYMLINKS JIT_SYMLINKS_ALL JIT_NONFILES JIT_NONFILES_ALL
        return 0
      fi
      continue
    fi
    if [ ! -f "$f" ] && [ -e "$f" ] && [ "$f" != "$base" ]; then
      rel="${f#"$base"/}"
      case "$rel" in
        */*/*)
          JIT_NONFILES="$JIT_NONFILES$f$JIT_NL"
          if [ "${#JIT_NONFILES}" -gt "$JIT_NONFILES_MAX" ]; then
            JIT_NONFILES="$JIT_NL"
            JIT_NONFILES_ALL=1
          fi
          ;;
      esac
    fi
    [ "$found" = 1 ] || continue
    [ "$f" != "$base" ] || continue
    parent="${f%/*}"
    case "$JIT_SYMLINKS" in
      *"$JIT_NL$parent$JIT_NL"*)
        JIT_SYMLINKS="$JIT_SYMLINKS$f$JIT_NL"
        if [ "${#JIT_SYMLINKS}" -gt "$JIT_SYMLINKS_MAX" ]; then
          JIT_SYMLINKS="$JIT_NL"
          JIT_SYMLINKS_ALL=1
          JIT_NONFILES="$JIT_NL"
          JIT_NONFILES_ALL=1
          export JIT_SYMLINKS JIT_SYMLINKS_ALL JIT_NONFILES JIT_NONFILES_ALL
          return 0
        fi
        ;;
    esac
  done
  export JIT_SYMLINKS JIT_SYMLINKS_ALL JIT_NONFILES JIT_NONFILES_ALL
}
jit_scan_symlinks "$JIT_BASE"
JIT_LOG_DISABLED=0
LOG_DIR="$JIT_BASE/.discovery/logs"
LOG_FILE="$LOG_DIR/hooks.log"
for _jit_p in "${JIT_BASE%/*}" "$JIT_BASE" "$JIT_BASE/.discovery" "$LOG_DIR"; do
  if [ -L "$_jit_p" ]; then JIT_LOG_DISABLED=1; fi
done
unset _jit_p
if [ "${JIT_SAMPLE_CALL:-}" = "1" ]; then JIT_LOG_DISABLED=1; fi
if [ ! -d "$JIT_BASE" ]; then JIT_LOG_DISABLED=1; fi
if [ "$JIT_LOG_DISABLED" = 0 ]; then
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2> /dev/null
  if [ -L "$LOG_FILE" ]; then JIT_LOG_DISABLED=1; fi
fi
jit_log_write() {
  if [ "$JIT_LOG_DISABLED" = 0 ]; then
    printf '%s\n' "$1" 2> /dev/null >> "$LOG_FILE"
  fi
}
JIT_STATE_DIR="$JIT_BASE/.discovery/state"
for _jit_p in "${JIT_BASE%/*}" "$JIT_BASE" "$JIT_BASE/.discovery" "$JIT_STATE_DIR"; do
  if [ -L "$_jit_p" ]; then JIT_STATE_DIR=""; fi
done
unset _jit_p
if [ -n "$JIT_STATE_DIR" ] && [ -d "$JIT_BASE" ] && [ ! -d "$JIT_STATE_DIR" ]; then
  if [ -d "$JIT_BASE/.discovery" ]; then
    if [ -w "$JIT_BASE/.discovery" ]; then mkdir -p "$JIT_STATE_DIR" 2> /dev/null; fi
  elif [ -w "$JIT_BASE" ]; then
    mkdir -p "$JIT_STATE_DIR" 2> /dev/null
  fi
fi
if [ ! -d "$JIT_STATE_DIR" ] || [ ! -w "$JIT_STATE_DIR" ]; then JIT_STATE_DIR=""; fi
JIT_MARK_END='--jit-marks-end--'
export JIT_MARK_END
JIT_MARKS_IN=()
JIT_MARKS_OK=0
JIT_TMP=""
_jit_printf_time=0
if printf -v _jit_probe '%(%H:%M:%S)T' -1 2> /dev/null; then
  case "$_jit_probe" in
    [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) _jit_printf_time=1 ;;
  esac
fi
unset _jit_probe
_ts() {
  local e="${EPOCHREALTIME:-}" s f out
  if [ "$_jit_printf_time" = 1 ]; then
    case "$e" in
      *[.,]*)
        s="${e%%[.,]*}"
        f="${e##*[.,]}000000"
        f="${f:0:6}"
        case "$s$f" in
          '' | *[!0-9]*) ;;
          *)
            printf -v out '%(%H:%M:%S)T' "$s"
            printf '%s.%03d\n' "$out" "$((10#$f / 1000))"
            return
            ;;
        esac
        ;;
    esac
  fi
  date '+%H:%M:%S.000'
}
JIT_CONFIG_REFUSED_MAX=4096
export JIT_CONFIG_REFUSED=""
export JIT_CONFIG_REFUSED_N=0
JIT_CONFIG_REFUSED_CUT=0
jit_config_refuse() {
  JIT_CONFIG_REFUSED_N=$((JIT_CONFIG_REFUSED_N + 1))
  if [ "${#JIT_CONFIG_REFUSED}" -gt "$JIT_CONFIG_REFUSED_MAX" ]; then
    if [ "$JIT_CONFIG_REFUSED_CUT" = 0 ]; then
      JIT_CONFIG_REFUSED_CUT=1
      JIT_CONFIG_REFUSED="$JIT_CONFIG_REFUSED$JIT_NL- the remaining refused lines are not listed here; the count above is the whole total"
    fi
    return 0
  fi
  JIT_CONFIG_REFUSED="$JIT_CONFIG_REFUSED${JIT_CONFIG_REFUSED:+$JIT_NL}- line $1: $2"
}
printf -v JIT_CFG_CR '\r'
printf -v JIT_CFG_DQ '\042'
printf -v JIT_CFG_SQ '\047'
jit_config_name_ok() {
  local LC_ALL=C
  case "$1" in *[!A-Za-z0-9_]*) return 1 ;; esac
  case "$1" in JIT_CONTEXT_?*) return 0 ;; esac
  case "$1" in DYNAMIC_RULES_?*) return 0 ;; esac
  case "$1" in DVSI_?*) return 0 ;; esac
  return 1
}
jit_load_config() {
  local LC_ALL=C
  local file="$1" line cfg_name value reason q rest tail lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%"$JIT_CFG_CR"}"
    while [ "$line" != "${line#[[:space:]]}" ]; do line="${line#[[:space:]]}"; done
    case "$line" in
      '' | \#*) continue ;;
      [e]xport[[:space:]]*)
        line="${line#[e]xport}"
        while [ "$line" != "${line#[[:space:]]}" ]; do line="${line#[[:space:]]}"; done
        ;;
    esac
    reason=""
    case "$line" in
      *=*)
        cfg_name="${line%%=*}"
        value="${line#*=}"
        ;;
      *)
        cfg_name=""
        value=""
        reason="not a KEY=VALUE assignment"
        ;;
    esac
    if [ -z "$reason" ] && ! jit_config_name_ok "$cfg_name"; then
      reason="unknown setting (only JIT_CONTEXT_*, DYNAMIC_RULES_* and DVSI_* are read)"
    fi
    if [ -n "$reason" ]; then
      jit_config_refuse "$lineno" "$reason"
      continue
    fi
    q="${value%"${value#?}"}"
    if [ "$q" = "$JIT_CFG_DQ" ] || [ "$q" = "$JIT_CFG_SQ" ]; then
      rest="${value#?}"
      case "$rest" in
        *"$q"*)
          tail="${rest#*"$q"}"
          while [ "$tail" != "${tail#[[:space:]]}" ]; do tail="${tail#[[:space:]]}"; done
          case "$tail" in
            '' | \#*) value="${rest%%"$q"*}" ;;
            *) reason="trailing text after the closing quote" ;;
          esac
          ;;
        *) reason="unterminated quote" ;;
      esac
    else
      case "$value" in
        *[[:space:]]#*) value="${value%%[[:space:]]#*}" ;;
      esac
      while [ "$value" != "${value%[[:space:]]}" ]; do value="${value%[[:space:]]}"; done
    fi
    if [ -n "$reason" ]; then
      jit_config_refuse "$lineno" "$reason"
      continue
    fi
    if [ "$cfg_name" = JIT_CONTEXT_INJECT ]; then
      case "$value" in
        summary) ;;
        full) ;;
        *)
          jit_config_refuse "$lineno" "not an injection mode (the modes are summary and full)"
          continue
          ;;
      esac
    fi
    if [ "$cfg_name" = JIT_CONTEXT_STOP_REPORT ]; then
      case "$value" in
        0) ;;
        1) ;;
        *)
          jit_config_refuse "$lineno" "not a stop-report toggle (0 or 1)"
          continue
          ;;
      esac
    fi
    if [ "$cfg_name" = JIT_CONTEXT_STATUS ]; then
      case "$value" in
        fired) ;;
        summary) ;;
        off) ;;
        *)
          jit_config_refuse "$lineno" "not a status mode (fired, summary or off)"
          continue
          ;;
      esac
    fi
    if [ "$cfg_name" = JIT_CONTEXT_MISSES ]; then
      case "$value" in
        on) ;;
        off) ;;
        *)
          jit_config_refuse "$lineno" "not a misses toggle (on or off)"
          continue
          ;;
      esac
    fi
    if [ "$cfg_name" = JIT_CONTEXT_LOG_MAX_BYTES ]; then
      case "$value" in
        0) ;;
        [1-9]*)
          case "$value" in
            *[!0-9]*)
              jit_config_refuse "$lineno" "not a byte count (0, or digits with no leading zero)"
              continue
              ;;
          esac
          ;;
        *)
          jit_config_refuse "$lineno" "not a byte count (0, or digits with no leading zero)"
          continue
          ;;
      esac
    fi
    printf -v "$cfg_name" '%s' "$value"
  done < "$file"
}
if [ -L "$JIT_BASE/config.env" ]; then
  JIT_CONFIG_REFUSED_N=1
  JIT_CONFIG_REFUSED="- the file itself: config.env is a symbolic link, so it was not read"
  jit_log_write "$(printf '[%s] config.env | refused: symbolic link' "$(_ts)")"
elif [ -f "$JIT_BASE/config.env" ]; then
  jit_load_config "$JIT_BASE/config.env"
  if [ "$JIT_CONFIG_REFUSED_N" -gt 0 ]; then
    jit_log_write "$(printf '[%s] config.env | %d line(s) refused\n%s' \
      "$(_ts)" "$JIT_CONFIG_REFUSED_N" "$JIT_CONFIG_REFUSED")"
  fi
fi
JIT_INJECT="${JIT_CONTEXT_INJECT:-full}"
case "$JIT_INJECT" in
  summary | full) ;;
  *) JIT_INJECT=full ;;
esac
JIT_STOP_REPORT="${JIT_CONTEXT_STOP_REPORT:-0}"
case "$JIT_STOP_REPORT" in
  0 | 1) ;;
  *) JIT_STOP_REPORT=0 ;;
esac
JIT_STATUS="${JIT_CONTEXT_STATUS:-summary}"
case "$JIT_STATUS" in
  fired | summary | off) ;;
  *) JIT_STATUS=summary ;;
esac
JIT_MISSES="${JIT_CONTEXT_MISSES:-on}"
case "$JIT_MISSES" in
  on | off) ;;
  *) JIT_MISSES=on ;;
esac
JIT_FM_NL="
"
JIT_AWK_FRONTMATTER='
  BEGIN { nf = split(fl, want, " ") }
  /^---$/ { n++; if (n == 2) exit; next }
  n == 1 {
    for (i = 1; i <= nf; i++) {
      f = want[i]
      if (f == "" || seen[f]) continue
      if (index($0, f ":") != 1) continue
      line = $0
      sub("^" f ": *", "", line)
      if (f == "mode") { gsub(/ /, "", line) }
      else {
        v = line
        sub(/[ \t\n\v\f\r]+$/, "", v)
        if (v ~ /^"[^"]*"$/) line = substr(v, 2, length(v) - 2)
      }
      seen[f] = 1
      printf "%s\t%s\n", f, line
      next
    }
  }
'
JIT_AWK_GUARD='
function jit_bad_pattern(p,   i, n, c, nx, depth, inbr, brpos) {
  if (p ~ /^@[A-Za-z][A-Za-z0-9-]*([[:space:]]|$)/) return "unexpanded macro -- rebuild the index with the rebuild-tsv tool this plugin ships"
  n = length(p)
  depth = 0
  inbr = 0
  brpos = 0
  for (i = 1; i <= n; i++) {
    c = substr(p, i, 1)
    if (c == "\\") {
      nx = substr(p, i + 1, 1)
      if (nx == "") return "trailing backslash"
      if (nx ~ /[[:alnum:]]/ && nx !~ /^[ntr]$/) return "undefined escape \\" nx
      if (nx > "\177") return "undefined escape \\ before a non-ASCII byte"
      i++
      continue
    }
    if (inbr) {
      if (c == "[" && substr(p, i + 1, 1) ~ /^[:.=]$/) {
        k = index(substr(p, i + 2), substr(p, i + 1, 1) "]")
        if (k == 0) return "unterminated [" substr(p, i + 1, 1) " element inside a character class"
        i = i + 2 + k
        continue
      }
      if (c == "]" && i != brpos + 1 && !(i == brpos + 2 && substr(p, brpos + 1, 1) == "^")) inbr = 0
      continue
    }
    if (c == "[") { inbr = 1; brpos = i; continue }
    if (c == "(") { depth++; continue }
    if (c == ")") { if (depth > 0) depth--; continue }
  }
  if (inbr) return "unterminated character class"
  if (depth > 0) return "unbalanced parenthesis"
  return ""
}
'
JIT_AWK_ENTRY='
function jit_row_id(layer, rown) {
  return layer " row " rown
}
function jit_entry_age(ident,   raw, n, i, ln, tp) {
  if (!jit_age_loaded) {
    jit_age_loaded = 1
    raw = ENVIRON["JIT_ENTRY_AGES"]
    if (raw != "") {
      n = split(raw, jit_age_lines, "\n")
      for (i = 1; i <= n; i++) {
        ln = jit_age_lines[i]
        if (ln == "") continue
        tp = index(ln, "\t")
        if (tp == 0) continue
        jit_age[substr(ln, 1, tp - 1)] = substr(ln, tp + 1) + 0
      }
    }
  }
  if (ident in jit_age) return jit_age[ident]
  return ""
}
function jit_log_text(s) {
  gsub(/[\n\r]/, " ", s)
  return s
}
function jit_log_name(f, layer, rown, why) {
  return (why == "not a bare file name") ? jit_row_id(layer, rown) : f
}
function jit_symlinked(p,   n, i, a) {
  if (ENVIRON["JIT_SYMLINKS_ALL"] == "1") return 1
  if (!jit_sym_init) {
    jit_sym_init = 1
    n = split(ENVIRON["JIT_SYMLINKS"], a, "\n")
    for (i = 1; i <= n; i++) if (a[i] != "") jit_sym[a[i]] = 1
  }
  return (p in jit_sym)
}
function jit_nonfile(p,   n, i, a) {
  if (ENVIRON["JIT_NONFILES_ALL"] == "1") return 1
  if (!jit_nf_init) {
    jit_nf_init = 1
    n = split(ENVIRON["JIT_NONFILES"], a, "\n")
    for (i = 1; i <= n; i++) if (a[i] != "") jit_nf[a[i]] = 1
  }
  return (p in jit_nf)
}
function jit_bad_entry_file(f, dir) {
  if (f == "") return ""
  if (index(f, "/") > 0 || index(f, "\\") > 0) return "not a bare file name"
  if (f == "." || f == "..") return "not a bare file name"
  if (substr(f, 1, 1) == ".") return "the entry file name begins with a dot, so rename it without one"
  if (dir != "") {
    if (ENVIRON["JIT_SYMLINKS_ALL"] == "1") return "this tree has too many symbolic links to check, so every row in it is refused"
    if (jit_symlinked(dir)) return "its layer directory is a symbolic link"
    if (jit_symlinked(dir "/" f)) return "the entry file is a symbolic link"
  }
  return ""
}
function jit_utf8_init(   k) {
  if (jit_utf8_ready) return
  jit_utf8_ready = 1
  for (k = 1; k <= 255; k++) jit_ord[sprintf("%c", k)] = k
  jit_hi_re = "[" sprintf("%c", 128) "-" sprintf("%c", 255) "]"
  jit_nul = sprintf("%c", 0)
}
function jit_bad_utf8(s,   i, n, b, need, lo, hi, j, cb) {
  jit_utf8_init()
  if (s !~ jit_hi_re) return 0
  n = length(s)
  for (i = 1; i <= n; i++) {
    b = jit_ord[substr(s, i, 1)] + 0
    if (b < 128) continue
    if (b < 194 || b > 244) return 1
    if (b < 224) { need = 1; lo = 128; hi = 191 }
    else if (b < 240) { need = 2; lo = (b == 224) ? 160 : 128; hi = (b == 237) ? 159 : 191 }
    else { need = 3; lo = (b == 240) ? 144 : 128; hi = (b == 244) ? 143 : 191 }
    if (i + need > n) return 1
    for (j = 1; j <= need; j++) {
      cb = jit_ord[substr(s, i + j, 1)] + 0
      if (j == 1) { if (cb < lo || cb > hi) return 1 }
      else if (cb < 128 || cb > 191) return 1
    }
    i += need
  }
  return 0
}
function jit_bad_bytes(s, what) {
  jit_utf8_init()
  if (length(jit_nul) == 1 && index(s, jit_nul) > 0) return what " contains a NUL byte"
  if (jit_bad_utf8(s)) return what " is not valid UTF-8"
  return ""
}
function jit_entry_why(path) {
  if (substr(path, length(path), 1) == "/") return "the row names no entry file"
  if (jit_nonfile(path)) return "the entry file is not a regular file"
  return ""
}
function jit_read_body(path,   line, r, first) {
  JIT_BODY = ""
  if ((r = jit_entry_why(path)) != "") return r
  first = 1
  while ((r = (getline line < path)) > 0) {
    JIT_BODY = JIT_BODY (first ? "" : "\n") line
    first = 0
  }
  close(path)
  if (r < 0) return "the entry file could not be read"
  return jit_bad_utf8(JIT_BODY) ? "the entry file is not valid UTF-8" : ""
}
function jit_refuse_add(list, item) {
  if (length(list) > 4096) {
    if (jit_refuse_cut) return list
    jit_refuse_cut = 1
    return list "\n- the remaining refused rows are not listed here; the count above is the whole total"
  }
  return list (list == "" ? "- " : "\n- ") item
}
function jit_unreached_add(list, item) {
  if (length(list) > 4096) {
    if (jit_unreached_cut) return list
    jit_unreached_cut = 1
    return list "\n- the remaining unreachable rows are not listed here; the count above is the whole total"
  }
  return list (list == "" ? "- " : "\n- ") item
}
function jit_refusal_notice(list, n) {
  return "# JIT Context: " n " rule(s) could not be evaluated, so they did NOT run\n" list \
    "\nA pattern the matcher cannot honour is not a rule that did not match, and until now the two looked identical. Lint the tree that owns these rules with the jit-dry-run tool this plugin ships, --base <tree>/.claude/jit-context"
}
function jit_layers_notice(list, n) {
  return "# JIT Context: " n " jit-context layer director" (n == 1 ? "y" : "ies") " could not be read, so no rule inside them ran\n" list "\nThese are directories under .claude/jit-context/<dimension>/ that exist and hold rules the matcher never opened. A layer that was never loaded and a layer whose rules never matched look identical from a session, which is why this says so. Name a layer directory with letters, digits, dot, underscore and hyphen only, and lint the tree with the jit-dry-run tool this plugin ships, --base <tree>/.claude/jit-context"
}
function jit_no_subject_notice(list, n) {
  return "# JIT Context: " n " tools rule(s) name this tool, but the hook could build no subject to match them against, so they did NOT run\n" list \
    "\nA tools rule is matched against a subject built from the tool_input keys `command`, `skill`, `file_path`, `pattern` and `subagent_type`. This dispatch carried none of them, so the rules above were indexed and counted and never consulted. Either they name a tool whose input this hook cannot read, or they name the wrong tool. A rule that cannot be reached is not a rule that did not match, and until now the two looked identical."
}
function jit_config_notice(list, n) {
  return "# JIT Context: " n " line(s) in .claude/jit-context/config.env were refused, so they did NOT take effect\n" list \
    "\nconfig.env is read as plain KEY=VALUE and is never executed. Only JIT_CONTEXT_*, DYNAMIC_RULES_* and DVSI_* settings are read; anything else, shell included, is refused. If a refused line is not one you wrote, treat that file as hostile -- it arrived with the repository."
}
function jit_worktree_notice(line) {
  return "# JIT Context: CLAUDE_PROJECT_DIR names a different git worktree than this shell is sitting in\n" line \
    "\nEvery hook resolves rules from CLAUDE_PROJECT_DIR, never from the working directory -- content injected below (or on any call in this session) can be served from the copy in the OTHER tree, silently (#402). Run /jit-context:doctor"
}
'
JIT_AWK_INJECT='
function jit_clip(s, n,   i) {
  if (length(s) <= n) return s
  s = substr(s, 1, n)
  if (length("é") > 1) {
    if (!jit_cont) {
      for (i = 128; i <= 191; i++) jit_cont = jit_cont sprintf("%c", i)
      for (i = 192; i <= 253; i++) jit_lead = jit_lead sprintf("%c", i)
    }
    i = 0
    while (i < 3 && length(s) > 0 && index(jit_cont, substr(s, length(s), 1)) > 0) {
      s = substr(s, 1, length(s) - 1)
      i++
    }
    if (length(s) > 0 && index(jit_lead, substr(s, length(s), 1)) > 0) s = substr(s, 1, length(s) - 1)
  }
  sub(/\r$/, "", s)
  sub(/[ \t\n\v\f\r]+$/, "", s)
  return s " [clipped]"
}
BEGIN {
  JIT_TRANSCLUDE_DEPTH_MAX = 3
  JIT_TRANSCLUDE_TOTAL_MAX = 12
}
function jit_transclude_component_ok(s) {
  if (s == "" || s == "." || s == "..") return 0
  if (substr(s, 1, 1) == ".") return 0
  if (s ~ /[^A-Za-z0-9._-]/) return 0
  return 1
}
function jit_transclude_resolve(spec,   n, parts, dim, layer, file, dir, path, why) {
  jit_transclude_why = ""
  n = split(spec, parts, "/")
  if (n != 3) { jit_transclude_why = "not a dimension/layer/file.md path"; return "" }
  dim = parts[1]; layer = parts[2]; file = parts[3]
  if (!jit_transclude_component_ok(dim) || !jit_transclude_component_ok(layer) || !jit_transclude_component_ok(file) || file !~ /\.md$/) {
    jit_transclude_why = "not a dimension/layer/file.md path"
    return ""
  }
  dir = ENVIRON["JIT_BASE"] "/" dim "/" layer
  why = jit_bad_entry_file(file, dir)
  if (why == "") {
    path = dir "/" file
    why = jit_entry_why(path)
  }
  if (why != "") { jit_transclude_why = why; return "" }
  return path
}
function jit_transclude_strip_frontmatter(body,   lines, n, i, out, closed, first, ln) {
  n = split(body, lines, "\n")
  if (n == 0) return body
  ln = lines[1]; sub(/\r$/, "", ln)
  if (ln != "---") return body
  closed = 0
  for (i = 2; i <= n; i++) {
    ln = lines[i]; sub(/\r$/, "", ln)
    if (ln == "---") { closed = 1; i++; break }
  }
  if (!closed) return body
  out = ""; first = 1
  for (; i <= n; i++) { out = out (first ? "" : "\n") lines[i]; first = 0 }
  return out
}
function jit_expand_transclusions(body, depth,   out, i, n, lines, first) {
  n = split(body, lines, "\n")
  out = ""; first = 1
  for (i = 1; i <= n; i++) {
    out = out (first ? "" : "\n") jit_transclude_expand_line(lines[i], depth)
    first = 0
  }
  return out
}
function jit_transclude_expand_line(line, depth,   trimmed, out, i, n, start, endp, spec, path, tent, expanded, saved_infence) {
  trimmed = line
  sub(/^[[:space:]]+/, "", trimmed)
  if (trimmed ~ /^```/) { jit_infence = !jit_infence; return line }
  if (jit_infence) return line
  if (index(line, "{{") == 0) return line
  out = ""
  n = length(line)
  i = 1
  while (i <= n) {
    start = index(substr(line, i), "{{")
    if (start == 0) { out = out substr(line, i); break }
    start = i + start - 1
    out = out substr(line, i, start - i)
    if (start > 1 && substr(line, start - 1, 1) == "$") {
      out = out "{{"
      i = start + 2
      continue
    }
    endp = index(substr(line, start + 2), "}}")
    if (endp == 0) { out = out substr(line, start); break }
    endp = start + 2 + endp - 1
    spec = substr(line, start + 2, endp - (start + 2))
    gsub(/^[[:space:]]+/, "", spec)
    gsub(/[[:space:]]+$/, "", spec)
    i = endp + 2
    if (jit_transclude_total >= JIT_TRANSCLUDE_TOTAL_MAX) {
      out = out "{{" spec "}} [jit] transclusion refused: this fire already spliced in " JIT_TRANSCLUDE_TOTAL_MAX " file(s), so this one was left as a pointer"
      continue
    }
    if (depth >= JIT_TRANSCLUDE_DEPTH_MAX) {
      out = out "{{" spec "}} [jit] transclusion refused: nested " JIT_TRANSCLUDE_DEPTH_MAX " deep already, so this one was left as a pointer"
      continue
    }
    path = jit_transclude_resolve(spec)
    if (path == "") {
      out = out "{{" spec "}} [jit] transclusion refused: " jit_transclude_why
      continue
    }
    if (index(jit_transclude_stack, "\n" path "\n") > 0) {
      out = out "{{" spec "}} [jit] transclusion refused: this would include itself (a cycle)"
      continue
    }
    if (!jit_entry_load(path, "full", 1, tent)) {
      out = out "{{" spec "}} [jit] transclusion refused: " (tent["why"] != "" ? tent["why"] : "the entry file is empty")
      continue
    }
    jit_transclude_total++
    jit_transclude_stack = jit_transclude_stack path "\n"
    saved_infence = jit_infence
    jit_infence = 0
    expanded = jit_expand_transclusions(jit_transclude_strip_frontmatter(tent["body"]), depth + 1)
    jit_infence = saved_infence
    jit_transclude_stack = substr(jit_transclude_stack, 1, length(jit_transclude_stack) - length(path) - 1)
    out = out expanded
  }
  return out
}
function jit_entry_load(path, def, keepbody, e,   line, ln, nfm, want, ident, val, nread, r) {
  e["body"] = ""; e["title"] = ""; e["desc"] = ""
  e["mode"] = def; e["fm"] = 0; e["badmode"] = 0; e["read"] = 0; e["injseen"] = 0
  e["pin"] = 0
  e["why"] = jit_entry_why(path)
  if (e["why"] != "") return 0
  nfm = 0; want = 1; nread = 0
  while ((r = (getline line < path)) > 0) {
    nread++
    e["read"] = 1
    if (want) e["body"] = e["body"] (nread == 1 ? "" : "\n") line
    ln = line
    sub(/\r$/, "", ln)
    if (ln == "---") {
      if (nfm == 0) {
        if (nread != 1) continue
        nfm = 1; e["fm"] = 1; continue
      }
      if (nfm == 1) {
        nfm = 2
        if (!keepbody && e["mode"] != "full") { e["body"] = ""; want = 0; break }
        continue
      }
      continue
    }
    if (nfm != 1) continue
    if (index(ln, ":") == 0) continue
    ident = substr(ln, 1, index(ln, ":") - 1)
    if (ident ~ /[^A-Za-z0-9_-]/) continue
    val = substr(ln, index(ln, ":") + 1)
    sub(/^[[:space:]]+/, "", val)
    sub(/[[:space:]]+$/, "", val)
    if (val ~ /^"[^"]*"$/) val = substr(val, 2, length(val) - 2)
    if (ident == "title") { if (e["title"] == "") e["title"] = val }
    else if (ident == "description") { if (e["desc"] == "") e["desc"] = val }
    else if (ident == "inject" && !e["injseen"]) {
      e["injseen"] = 1
      gsub(/[[:space:]]/, "", val)
      val = tolower(val)
      if (val == "summary" || val == "full") { e["mode"] = val; e["pin"] = 1 }
      else if (val != "") e["badmode"] = 1
    }
  }
  close(path)
  if (r < 0) { e["why"] = "the entry file could not be read"; return 0 }
  if (jit_bad_utf8(e["body"] e["title"] e["desc"])) {
    e["why"] = "the entry file is not valid UTF-8"
    return 0
  }
  if (!e["fm"]) { e["mode"] = "full"; e["pin"] = 1 }
  return e["read"]
}
function jit_badmode_note(e) {
  if (!e["badmode"]) return ""
  return "\n[jit] The inject: value in this entry is not summary or full, so the project default applied."
}
function jit_inject_text(e, rel, selfpath,   out, tbody) {
  if (e["mode"] == "full") {
    if (e["body"] != "" && e["body"] ~ /^[[:space:]]*$/) return "[jit] The entry file has no text to inject." jit_badmode_note(e)
    jit_transclude_total = 0
    jit_transclude_stack = (selfpath != "" ? "\n" selfpath "\n" : "\n")
    jit_infence = 0
    tbody = (index(e["body"], "{{") > 0) ? jit_expand_transclusions(e["body"], 0) : e["body"]
    return tbody jit_badmode_note(e)
  }
  out = ""
  if (e["title"] != "") out = jit_clip(e["title"], 160)
  if (e["desc"] != "") out = out (out == "" ? "" : "\n") jit_clip(e["desc"], 400)
  else out = out (out == "" ? "" : "\n") "[jit] There is no description: in this entry, so a match can only name it. Add one and the next match will say what it holds."
  out = out jit_badmode_note(e)
  return out "\n[jit] Summary only -- read " rel " for the entry."
}
function jit_inject_tag(e,   t) {
  if (e["mode"] == "full") t = "[full"
  else if (e["desc"] == "") t = "[summary:no-description"
  else t = "[summary"
  return t (e["badmode"] ? ":badmode" : "") "]"
}
'
JIT_AWK_FOLD='
function jit_fold_latin1(s,   i, p, out) {
  if (_jit_fold_n == 0)
    _jit_fold_n = split("á a à a â a ä a ã a å a æ ae ç c é e è e ê e ë e í i ì i î i ï i ñ n " \
                        "ó o ò o ô o ö o õ o œ oe ß ss ú u ù u û u ü u ý y ÿ y " \
                        "Á a À a Â a Ä a Ã a Å a Æ ae Ç c É e È e Ê e Ë e Í i Ì i Î i Ï i Ñ n " \
                        "Ó o Ò o Ô o Ö o Õ o Œ oe Ú u Ù u Û u Ü u Ý y", _jit_fold_tr, "[ ]")
  for (i = 1; i + 1 <= _jit_fold_n; i += 2) {
    out = ""
    while ((p = index(s, _jit_fold_tr[i])) > 0) {
      out = out substr(s, 1, p - 1) _jit_fold_tr[i+1]
      s = substr(s, p + length(_jit_fold_tr[i]))
    }
    s = out s
  }
  return s
}
'
JIT_AWK_HEREDOC='
function jit_heredoc_opener_is_suppressed(prefix, state0,    i, c, state, n, q1, q2, bs) {
  q1 = sprintf("%c", 39)
  q2 = sprintf("%c", 34)
  bs = sprintf("%c", 92)
  state = state0
  n = length(prefix)
  for (i = 1; i <= n; i++) {
    c = substr(prefix, i, 1)
    if (state == 0) {
      if (c == q1) state = 1
      else if (c == q2) state = 2
      else if (c == "\043") return 1
      else if (c == bs) i++
    } else if (state == 1) {
      if (c == q1) state = 0
    } else if (state == 2) {
      if (c == bs) i++
      else if (c == q2) state = 0
    }
  }
  return (state != 0)
}
function jit_heredoc_line_exit_state(line, state0,    i, c, len, q1, q2, bs, state) {
  q1 = sprintf("%c", 39)
  q2 = sprintf("%c", 34)
  bs = sprintf("%c", 92)
  state = state0
  len = length(line)
  for (i = 1; i <= len; i++) {
    c = substr(line, i, 1)
    if (state == 0) {
      if (c == q1) state = 1
      else if (c == q2) state = 2
      else if (c == "\043") break
      else if (c == bs) i++
    } else if (state == 1) {
      if (c == q1) state = 0
    } else if (state == 2) {
      if (c == bs) i++
      else if (c == q2) state = 0
    }
  }
  return state
}
function jit_heredoc_quote_states(lines, n, qin,    i, state) {
  state = 0
  for (i = 1; i <= n; i++) {
    qin[i] = state
    state = jit_heredoc_line_exit_state(lines[i], state)
  }
}
function jit_strip_heredoc_body(s, unconditional,    n, lines, i, j, out, strip_tabs, delim, line, rest, probed, op, word, prefix, q1, q2, q3, qclass, close_i, quote_in, lt2) {
  lt2 = sprintf("%c%c", 60, 60)
  q1 = sprintf("%c", 39)
  q2 = sprintf("%c", 34)
  q3 = sprintf("%c%c", 92, 92)
  qclass = "[" q1 q2 q3 "]?"
  n = split(s, lines, "\n")
  jit_heredoc_quote_states(lines, n, quote_in)
  out = ""
  i = 1
  while (i <= n) {
    line = lines[i]
    probed = " " line
    close_i = 0
    if (match(probed, "[^<]" lt2 "-?[ \t]*" qclass "[A-Za-z_][A-Za-z0-9_]*" qclass)) {
      prefix = substr(probed, 1, RSTART)
      if (!jit_heredoc_opener_is_suppressed(prefix, quote_in[i])) {
        op = substr(probed, RSTART + 1, RLENGTH - 1)
        strip_tabs = (substr(op, 1, 3) == lt2 "-")
        word = op
        sub("^" lt2 "-?[ \t]*", "", word)
        gsub("[" q1 q2 q3 "]", "", word)
        if (word != "" && (unconditional || jit_heredoc_opener_is_known_sink(line))) {
          delim = word
          for (j = i + 1; j <= n; j++) {
            rest = lines[j]
            sub(/\r$/, "", rest)
            if (strip_tabs) sub(/^\t+/, "", rest)
            if (rest == delim) { close_i = j; break }
          }
        }
      }
    }
    out = (out == "") ? line : out "\n" line
    if (close_i > 0) {
      i = close_i + 1
    } else {
      i++
    }
  }
  return out
}
function jit_heredoc_opener_has_danger_token(line) {
  if (index(line, "|") > 0) return 1
  if (index(line, "$(") > 0) return 1
  if (index(line, "`") > 0) return 1
  if (index(line, ">(") > 0) return 1
  if (index(line, "<(") > 0) return 1
  return 0
}
function jit_heredoc_opener_is_known_sink(line) {
  if (jit_heredoc_opener_has_danger_token(line)) return 0
  if (line ~ /(^|[;&|])[ \t]*cat([ \t]|$)/ && line ~ />/) return 1
  if (line ~ /(^|[;&|])[ \t]*tee[ \t]+[^ \t;&|\n]/) return 1
  if (line ~ /(^|[;&|])[ \t]*(\.\/)?supertool([ \t]|$)/) return 1
  if (line ~ /(^|[;&|])[ \t]*git[ \t]+commit([ \t]|$)/ && line ~ /(^|[ \t])(-F|--file)[ \t]*-([ \t]|$)/) return 1
  if (line ~ /(^|[;&|])[ \t]*gh([ \t]|$)/ && line ~ /(^|[ \t])(--body-file|-F)[ \t]*-([ \t]|$)/) return 1
  return 0
}
'
JIT_AWK_JSON='
function jit_trailing_backslashes(s,   c, n) {
  n = length(s); c = 0
  while (c < n && substr(s, n - c, 1) == "\\") c++
  return c
}
function jit_json_fields(s, raw, fs, fe,   n, i, k) {
  n = split(s, raw, "\"")
  k = 1
  fs[1] = 1
  for (i = 1; i < n; i++) {
    if (jit_trailing_backslashes(raw[i]) % 2 == 1) continue
    fe[k] = i
    k++
    fs[k] = i + 1
  }
  fe[k] = n
  return k
}
function jit_hook_fields(raw, fs, fe, n, top_wanted, ti_wanted, TOP, TI,   depth, ti_depth, pending_ident, pending_key_depth, i, c, ch, txt, val, nxt, is_ident) {
  depth = 0
  ti_depth = -1
  pending_ident = ""
  pending_key_depth = -1
  for (i = 1; i <= n; i++) {
    if (i % 2 == 1) {
      txt = raw[fs[i]]
      for (c = 1; c <= length(txt); c++) {
        ch = substr(txt, c, 1)
        if (ch == "{") {
          depth++
          if (pending_ident == "tool_input" && pending_key_depth == 1 && ti_depth == -1) ti_depth = depth
        } else if (ch == "}") {
          if (depth == ti_depth) ti_depth = -1
          depth--
        }
      }
      continue
    }
    if (fs[i] != fe[i]) { pending_ident = ""; pending_key_depth = -1; continue }
    val = raw[fs[i]]
    is_ident = 0
    if (i + 1 <= n) {
      nxt = raw[fs[i+1]]
      if (nxt ~ /^[[:space:]]*:/) is_ident = 1
    }
    if (!is_ident) { pending_ident = ""; pending_key_depth = -1; continue }
    pending_ident = val
    pending_key_depth = depth
    if (i + 2 > n) continue
    if (depth == 1) {
      if ((val in top_wanted) && !(val in TOP)) TOP[val] = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    } else if (depth == ti_depth) {
      if ((val in ti_wanted) && !(val in TI)) TI[val] = jit_unescape(jit_field(raw, fs[i+2], fe[i+2]))
    }
  }
}
function jit_session_key(raw, fs, fe, n,   i, k) {
  for (i = 2; i + 2 <= n; i += 2) {
    if (fs[i] != fe[i]) continue
    if (raw[fs[i]] != "session_id") continue
    if (fs[i+2] != fe[i+2]) return ""
    k = raw[fs[i+2]]
    if (k == "" || length(k) > 64) return ""
    if (k ~ /[^A-Za-z0-9_-]/) return ""
    return k
  }
  return ""
}
function jit_agent_key(raw, fs, fe, n,   i, v, base) {
  for (i = 2; i + 2 <= n; i += 2) {
    if (fs[i] != fe[i]) continue
    if (raw[fs[i]] != "transcript_path") continue
    if (fs[i+2] != fe[i+2]) return ""
    v = raw[fs[i+2]]
    if (v == "") return ""
    base = v
    gsub(/.*[\/\\]/, "", base)
    sub(/\.jsonl$/, "", base)
    if (base == "" || length(base) > 64) return ""
    if (base ~ /[^A-Za-z0-9_-]/) return ""
    return base
  }
  return ""
}
function jit_stop_hook_active(raw, fs, fe, n,   i) {
  for (i = 2; i <= n; i += 2) {
    if (fs[i] != fe[i]) continue
    if (raw[fs[i]] != "stop_hook_active") continue
    return (raw[fe[i] + 1] ~ /^[[:space:]]*:[[:space:]]*true/) ? 1 : 0
  }
  return 0
}
function jit_shown_file(dir, kind, raw, fs, fe, n,   k) {
  return jit_shown_path(dir, kind, jit_session_key(raw, fs, fe, n))
}
function jit_agent_shown_file(dir, kind, raw, fs, fe, n,   k) {
  k = jit_agent_key(raw, fs, fe, n)
  if (k == "") k = jit_session_key(raw, fs, fe, n)
  return jit_shown_path(dir, kind, k)
}
function jit_shown_path(dir, kind, k) {
  if (dir == "" || k == "") return ""
  return dir "/" kind "-shown-" k ".txt"
}
function jit_shown_load(file, set,   line) {
  if (file == "") return
  while ((getline line < file) > 0) set[line] = 1
}
function jit_shown_mark(file, ident) {
  if (file == "") return
  JIT_MARKS = JIT_MARKS file "\t" ident "\n"
}
function jit_loc_key(dim, layer, file) {
  return "loc:" dim ":" layer ":" file
}
function jit_shown_flush(out) {
  printf "%s%s\n", JIT_MARKS, ENVIRON["JIT_MARK_END"] > out
}
function jit_field(raw, a, b,   o, i) {
  if (a == "" || b == "" || a > b) return ""
  if (a == b) return raw[a]
  o = raw[a]
  for (i = a + 1; i <= b; i++) o = o "\"" raw[i]
  return o
}
function jit_unescape(s,   n, i, c, nx, o) {
  if (index(s, "\\") == 0) return s
  n = length(s); o = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c != "\\" || i == n) { o = o c; continue }
    nx = substr(s, i + 1, 1)
    if (nx == "n") o = o "\n"
    else if (nx == "t") o = o "\t"
    else if (nx == "r") o = o "\r"
    else if (nx == "b") o = o "\b"
    else if (nx == "f") o = o "\f"
    else if (nx == "\"") o = o "\""
    else if (nx == "/") o = o "/"
    else if (nx == "\\") o = o "\\"
    else { o = o c nx; i++; continue }
    i++
  }
  return o
}
'
JIT_AWK_BLK_BUILD='
function jit_blk_prepend(text,   i) {
  for (i = nblk; i >= 1; i--) blk[i + 1] = blk[i]
  blk[1] = text
  nblk++
}
function jit_blk_join(   bi, out, manifest) {
  if (nblk == 0) return ""
  manifest = "# JIT-CTX-BLOCKS " nblk
  out = ""
  for (bi = 1; bi <= nblk; bi++) {
    manifest = manifest " " length(blk[bi])
    out = (out == "") ? blk[bi] : out "\n---\n" blk[bi]
  }
  return manifest "\n" out
}
'
JIT_AWK_BLOCKS='
function jit_unescape_blocks(s,   n, i, c, nx, hx, v, o) {
  if (index(s, "\\") == 0) return s
  n = length(s); o = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c != "\\" || i == n) { o = o c; continue }
    nx = substr(s, i + 1, 1)
    if (nx == "n") { o = o "\n"; i++; continue }
    if (nx == "t") { o = o "\t"; i++; continue }
    if (nx == "r") { o = o "\r"; i++; continue }
    if (nx == "b") { o = o "\b"; i++; continue }
    if (nx == "f") { o = o "\f"; i++; continue }
    if (nx == "\"") { o = o "\""; i++; continue }
    if (nx == "/") { o = o "/"; i++; continue }
    if (nx == "\\") { o = o "\\"; i++; continue }
    if (nx == "u" && substr(s, i, 6) ~ /^\\u00[0-9a-fA-F][0-9a-fA-F]$/) {
      hx = tolower(substr(s, i + 4, 2))
      v = index("0123456789abcdef", substr(hx, 1, 1)) - 1
      v = v * 16 + index("0123456789abcdef", substr(hx, 2, 1)) - 1
      if (v <= 31) { o = o sprintf("%c", v); i += 5; continue }
    }
    o = o c nx; i++; continue
  }
  return o
}
function jit_split_ctx_blocks(ctx,   nl_pos, header, body_rest, hn, hf, declared_n, pos, bi, blen, rest, p1, p2, p) {
  jit_blk_n = 0
  jit_blk_manifest_ok = 0
  delete jit_blk_body
  if (substr(ctx, 1, 17) == "# JIT-CTX-BLOCKS ") {
    nl_pos = index(ctx, "\n")
    if (nl_pos > 0) {
      header = substr(ctx, 1, nl_pos - 1)
      body_rest = substr(ctx, nl_pos + 1)
      hn = split(header, hf, " ")
      declared_n = hf[3] + 0
      if (hn == 3 + declared_n && declared_n >= 0 && hf[1] == "\043" && hf[2] == "JIT-CTX-BLOCKS") {
        jit_blk_manifest_ok = 1
        pos = 1
        for (bi = 1; bi <= declared_n; bi++) {
          blen = hf[3 + bi] + 0
          if (blen < 0 || pos + blen - 1 > length(body_rest)) { jit_blk_manifest_ok = 0; break }
          jit_blk_body[bi] = substr(body_rest, pos, blen)
          pos += blen
          if (bi < declared_n) {
            if (substr(body_rest, pos, 5) != "\n---\n") { jit_blk_manifest_ok = 0; break }
            pos += 5
          }
        }
        if (jit_blk_manifest_ok && pos - 1 != length(body_rest)) jit_blk_manifest_ok = 0
        if (jit_blk_manifest_ok) jit_blk_n = declared_n
      }
    }
  }
  if (!jit_blk_manifest_ok) {
    rest = ctx
    jit_blk_n = 0
    while (1) {
      p1 = index(rest, "\n---\n# Vocabulary: ")
      p2 = index(rest, "\n---\n# JIT Context: ")
      if (p1 == 0 && p2 == 0) { jit_blk_n++; jit_blk_body[jit_blk_n] = rest; break }
      if (p1 == 0) p = p2
      else if (p2 == 0) p = p1
      else p = (p1 < p2) ? p1 : p2
      jit_blk_n++
      jit_blk_body[jit_blk_n] = substr(rest, 1, p - 1)
      rest = substr(rest, p + 5)
    }
  }
}
'
JIT_AWK_ENVELOPE='
function jit_envelope_inject(event, text_escaped) {
  if (text_escaped == "") return "{}"
  return "{\"hookSpecificOutput\":{\"hookEventName\":\"" event "\",\"additionalContext\":\"" text_escaped "\"}}"
}
function jit_envelope_block(reason_escaped) {
  return "{\"decision\":\"block\",\"reason\":\"" reason_escaped "\"}"
}
function jit_envelope_empty() {
  return "{}"
}
'
JIT_AWK_ENVELOPE_SYSMSG='
function jit_fmt_bytes(n) {
  if (n < 1000) return n "b"
  return sprintf("%.1fk", n / 1000)
}
function jit_envelope_inject_sysmsg(event, text_escaped, sysmsg_escaped) {
  if (text_escaped == "" && sysmsg_escaped == "") return "{}"
  if (text_escaped == "") return "{\"systemMessage\":\"" sysmsg_escaped "\"}"
  if (sysmsg_escaped == "") return jit_envelope_inject(event, text_escaped)
  return "{\"hookSpecificOutput\":{\"hookEventName\":\"" event "\",\"additionalContext\":\"" text_escaped "\"},\"systemMessage\":\"" sysmsg_escaped "\"}"
}
function jit_envelope_block_sysmsg(reason_escaped, sysmsg_escaped) {
  if (sysmsg_escaped == "") return jit_envelope_block(reason_escaped)
  return "{\"decision\":\"block\",\"reason\":\"" reason_escaped "\",\"systemMessage\":\"" sysmsg_escaped "\"}"
}
'
jit_frontmatter_many() { # VAR, entry file, field...
  local _v="$1" _file="$2" _fields="${*:3}"
  printf -v "$_v" '%s%s' "$JIT_FM_NL" \
    "$(LC_ALL=C awk -v fl="$_fields" "$JIT_AWK_FRONTMATTER" "$_file")"
}
jit_fm_get() { # VAR, memo, field
  local _probe="$JIT_FM_NL$3	" _rest
  case "$2" in
    *"$_probe"*)
      _rest="${2#*"$_probe"}"
      printf -v "$1" '%s' "${_rest%%"$JIT_FM_NL"*}"
      ;;
    *) printf -v "$1" '%s' "" ;;
  esac
}
JIT_VALID_MODE_RE='^(remind|block|once)(,(remind|block|once))*$'
JIT_VALID_REQUIRES_RE='^[A-Za-z0-9._+-]{1,255}$'
JIT_MACRO_ANCHOR='(^|[;&|\n] *)'
JIT_MACRO_WRAP='(([a-z_][a-z0-9_]*=[^[:space:];&|]*|rtk|command|[e]nv|sudo|nohup|nice|time)[[:space:]]+)*'
JIT_MACRO_OPT='(-[^[:space:];&|]*[[:space:]]+([^-;&|[:space:]][^[:space:];&|]*[[:space:]]+)?)*'
JIT_MACRO_END='($|[[:space:];&|])'

# --- Shared JSON string reader ---------------------------------------------
# Prepended to all three hook programs. Every hook used to read its payload with
# `split(input, f, "\\"")` and take the raw field, which is wrong twice:
JIT_LOG_MATCHES_MAX=2048
JIT_LOG_ARROW='<''<'
export JIT_NAME_WITHHELD='<withheld: not a plain name>'
JIT_LAYERS_MAX=64
JIT_LAYERS_REFUSED_MAX=4096
JIT_LAYERS=""
export JIT_LAYERS_REFUSED=""
export JIT_LAYERS_REFUSED_N=0
JIT_LAYERS_REFUSED_CUT=0
jit_layer_refuse() {
  JIT_LAYERS_REFUSED_N=$((JIT_LAYERS_REFUSED_N + 1))
  if [ "${#JIT_LAYERS_REFUSED}" -gt "$JIT_LAYERS_REFUSED_MAX" ]; then
    if [ "$JIT_LAYERS_REFUSED_CUT" = 0 ]; then
      JIT_LAYERS_REFUSED_CUT=1
      JIT_LAYERS_REFUSED="$JIT_LAYERS_REFUSED$JIT_NL- the remaining refused layer directories are not listed here; the count above is the whole total"
    fi
    return 0
  fi
  JIT_LAYERS_REFUSED="$JIT_LAYERS_REFUSED${JIT_LAYERS_REFUSED:+$JIT_NL}- $1: $2"
}
jit_scan_layers() {
  local base="$1" dim="$2" d name tsv seen=0 kept=0 cut=0
  local LC_ALL=C
  JIT_LAYERS=""
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    name="${d##*/}"
    seen=$((seen + 1))
    if [ "$kept" -ge "$JIT_LAYERS_MAX" ]; then
      if [ "$cut" = 0 ]; then
        cut=1
        jit_layer_refuse "$dim" "the layer directories after the first $JIT_LAYERS_MAX were not read"
      fi
      continue
    fi
    case "$name" in
      '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*)
        jit_layer_refuse "$dim" "layer directory $seen was not read: the directory name is not a plain name"
        continue
        ;;
    esac
    if [ "${#name}" -gt 64 ]; then
      jit_layer_refuse "$dim" "layer directory $seen was not read: the directory name is longer than 64 bytes"
      continue
    fi
    if [ ! -r "$d" ] || [ ! -x "$d" ]; then
      jit_layer_refuse "$dim" "layer directory $seen was not read: the directory could not be opened"
      continue
    fi
    for tsv in "$d/00-index.tsv" "$d/01-paths.tsv"; do
      [ -e "$tsv" ] || continue
      if [ ! -r "$tsv" ]; then
        jit_layer_refuse "$dim" "layer directory $seen was not read: an index inside it could not be opened"
        continue 2
      fi
    done
    JIT_LAYERS="$JIT_LAYERS${JIT_LAYERS:+ }$name"
    kept=$((kept + 1))
  done
}
JIT_ENTRY_AGES_MAX=8192
export JIT_ENTRY_AGES=""
export JIT_KEYWORD_WITHHELD='<withheld: not a plain keyword>'
JIT_MISSING_REQUIRES_MAX=4096
BASE="$(pwd)/.claude/jit-context"
TEXT=""
TEXT_SET=0
FORMAT="text"
SUMMARY=0
LIMIT=0
usage() {
  sed -n '2,42p' "$0"
  exit "${1:-0}"
}
need_value() {
  echo "jit-match: SKIPPED -- $1 needs a value" >&2
  echo "  run with --help for the accepted flags. Nothing was checked." >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ $# -ge 2 ] || need_value "$1"
      BASE="$2"
      shift 2
      ;;
    --text)
      [ $# -ge 2 ] || need_value "$1"
      TEXT="$2"
      TEXT_SET=1
      shift 2
      ;;
    --format)
      [ $# -ge 2 ] || need_value "$1"
      FORMAT="$2"
      shift 2
      ;;
    --limit)
      [ $# -ge 2 ] || need_value "$1"
      LIMIT="$2"
      shift 2
      ;;
    --summary)
      SUMMARY=1
      shift
      ;;
    -h | --help) usage 0 ;;
    *)
      echo "jit-match: SKIPPED -- unknown argument: $1" >&2
      usage 2
      ;;
  esac
done
BASE="${BASE%/}"
case "$FORMAT" in
  text | json) : ;;
  *)
    echo "jit-match: SKIPPED -- --format must be text or json, got: $FORMAT" >&2
    echo "  Nothing was checked." >&2
    exit 2
    ;;
esac
case "$LIMIT" in
  '' | *[!0-9]*)
    echo "jit-match: SKIPPED -- --limit must be a non-negative integer, got: $LIMIT" >&2
    echo "  Nothing was checked." >&2
    exit 2
    ;;
esac
case "$BASE" in
  */.claude/jit-context) PROJECT="${BASE%/.claude/jit-context}" ;;
  *)
    echo "jit-match: SKIPPED -- --base must be a <project>/.claude/jit-context path, got: $BASE" >&2
    echo "  jit-match runs the real hook against a project directory; there is nothing to point it at." >&2
    exit 2
    ;;
esac
if [ ! -d "$BASE" ]; then
  echo "jit-match: SKIPPED -- no such directory: $BASE" >&2
  echo "  Nothing was checked. This is not a clean result." >&2
  exit 2
fi
if [ "$TEXT_SET" = 0 ]; then
  if [ -t 0 ]; then
    echo "jit-match: SKIPPED -- no text. Pass --text \"...\" or pipe text on stdin." >&2
    echo "  Nothing was checked." >&2
    exit 2
  fi
  TEXT="$(cat)"
fi
if [ -z "$TEXT" ]; then
  echo "jit-match: SKIPPED -- the text is empty." >&2
  echo "  Nothing was checked." >&2
  exit 2
fi
json_escape() {
  printf '%s' "$1" | LC_ALL=C perl -0777 -pe '
    s/\\/\\\\/g;
    s/"/\\"/g;
    s/\t/\\t/g;
    s/\r/\\r/g;
    s/\n/\\n/g;
  '
}
PAYLOAD="{\"prompt\":\"$(json_escape "$TEXT")\"}"
jit_scan_layers "$BASE/vocabulary" vocabulary
VOCAB_LAYERS="$JIT_LAYERS"
HOOK_ENV=(CLAUDE_PROJECT_DIR="$PROJECT" JIT_SAMPLE_CALL=1)
if [ "$SUMMARY" = 1 ]; then
  HOOK_ENV+=(JIT_CONTEXT_INJECT=summary)
fi
jit_match_run_hook() {
  (
    for kv in "${HOOK_ENV[@]}"; do export "$kv"; done
    bash "$SCRIPT_DIR/pre-prompt-hook.sh"
  )
}
HOOK_STDERR_CHECKED=0
ERRF="$(mktemp "${TMPDIR:-/tmp}/claude-jit-match-XXXXXXXX" 2> /dev/null)" || ERRF=""
if [ -n "$ERRF" ]; then
  HOOK_OUT="$(printf '%s' "$PAYLOAD" | jit_match_run_hook 2> "$ERRF")"
  HOOK_STDERR="$(cat "$ERRF" 2> /dev/null)"
  HOOK_STDERR_CHECKED=1
  rm -f "$ERRF"
else
  HOOK_OUT="$(printf '%s' "$PAYLOAD" | jit_match_run_hook 2> /dev/null)"
  HOOK_STDERR=""
fi
RESULT="$(
  printf '%s' "$HOOK_OUT" | LC_ALL=C awk \
    -v format="$FORMAT" -v limit="$LIMIT" \
    -v vocab_layers="$VOCAB_LAYERS" -v vocab_base="$BASE/vocabulary" \
    "$JIT_AWK_JSON$JIT_AWK_ENTRY$JIT_AWK_BLOCKS"'
function emit_json_str(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s)
  gsub(/\n/, "\\n", s)
  gsub(/\r/, "\\r", s)
  for (jit_c00 = 0; jit_c00 <= 31; jit_c00++) {
    if (jit_c00 == 9 || jit_c00 == 10 || jit_c00 == 13) continue
    jit_c00_ch = sprintf("%c", jit_c00)
    if (length(jit_c00_ch) == 0) continue
    if (index(s, jit_c00_ch) > 0) gsub(jit_c00_ch, sprintf("\\u%04x", jit_c00), s)
  }
  return s
}
# jit_unescape_blocks() (common.sh, JIT_AWK_BLOCKS) is what this file calls below to
# decode a block-carrying field instead of jit_unescape() alone -- it moved here (#223)
# alongside jit_split_ctx_blocks() for the same reason as that function: jit-dry-run.sh
# report_hook() needs the identical decode before it can trust a block header, and a
# second copy here is what let the two drift out of step in the first place. It replaced
# the two-pass jit_decode_u00(jit_unescape(...)) idiom in #226, fusing both into one walk
# so an entry own escaped backslash can never be mistaken for a genuine \u00XX escape
# once jit_unescape() has already run on it. See its own comment in common.sh.
# --- The tree own index, loaded once, used only to VERIFY -------------------------------
# This does NOT reimplement the matcher. It does not fold accents, does not apply the
# LC_ALL=C keyword-lookup this whole design deliberately leaves to the real hook, and it
# never DECIDES that a match fired -- it only answers a narrower, purely structural
# question: does a (file, keyword) pair the hook claims fired actually exist as a row in
# this tree own 00-index.tsv? A row that does not exist could not have caused a real
# match, whatever the hook output claims.
#
# Why this exists (#202/#205/#189 review, maintainer override on PR #216): the
# index()-based block splitter above cannot tell a genuine hook-emitted join from the
# same literal bytes appearing inside one entry own author-controlled body -- paths/00-
# manual/hooks.md says plainly that .claude/jit-context/ is attacker-controlled input.
# Proven unsolvable from ctx alone: `matched = matched "\n---\n" vh "\n" vc` in
# pre-prompt-hook.sh produces a BYTE-IDENTICAL join to an entry whose own full-mode body
# (raw file content, no fixed ending) happens to end in the same five-plus-header bytes,
# so no property of the SURROUNDING text can ever distinguish the two cases -- reasoned
# through and confirmed against the real hook source, not assumed.
#
# What this DOES close: the specific reproduction that motivated it -- an entry naming a
# file/keyword pair that does not exist anywhere in the tree own index at all. That is a
# decidable, false-positive-free question: every REAL match necessarily corresponds to a
# real index row, by construction, so this can never flag a genuine match.
#
# What this does NOT close, said once rather than reasoned about twice: a forged entry
# that instead names another file own REAL keyword already indexed elsewhere in the SAME
# tree would pass this check too -- verifying existence is not verifying that THIS TEXT
# caused THAT row to fire, and closing that gap needs the hook own match count, which
# only the protocol change the maintainer accepted as out-of-scope reaches. Said in the
# report, not silently narrowed here.
function jit_index_load(   nl, li, layer, lookup, vl, why, vf) {
  if (jit_idx_loaded) return
  jit_idx_loaded = 1
  nl = split(vocab_layers, jit_idx_layers, " ")
  for (li = 1; li <= nl; li++) {
    layer = jit_idx_layers[li]
    lookup = vocab_base "/" layer "/00-index.tsv"
    while ((getline vl < lookup) > 0) {
      why = jit_bad_bytes(vl, "the index row")
      if (why != "") continue
      split(vl, vf, "\t")
      if (vf[1] == "" || vf[2] == "") continue
      jit_idx[vf[2] "\t" vf[1]] = 1
    }
    close(lookup)
  }
}
# mkw may carry more than one keyword, "|"-joined (jit_inject_text/vmatch join multiple
# keywords that matched the same file that way -- see the vmatch[vfile] build in
# pre-prompt-hook.sh). Verified when AT LEAST ONE of them is a real row for mfile: that is
# the OR a real match would satisfy, since any one of them firing is what puts the file in
# vmatch to begin with.
function jit_index_verified(mfile, mkw,   nk, ki, kws) {
  jit_index_load()
  if (mkw == "") return 0
  nk = split(mkw, kws, "|")
  for (ki = 1; ki <= nk; ki++) {
    if ((mfile "\t" kws[ki]) in jit_idx) return 1
  }
  return 0
}
{ input = input $0 }
END {
  n = jit_json_fields(input, raw, fs, fe)
  ctx = ""
  # Stride 2, matching pre-prompt-hook.sh own scan for "prompt": a quoted key is always
  # followed by ONE more field holding the colon (and, for a nested object, the opening
  # brace too) before the next quoted field -- the value, or the next nested key. This
  # response is a fixed, known shape (this script own hook, this script own envelope), so
  # jumping straight to i+2 for the value is exact rather than a guess.
  for (i = 1; i + 2 <= n; i++) {
    if (fs[i] != fe[i]) continue
    if (jit_field(raw, fs[i], fe[i]) != "additionalContext") continue
    ctx = jit_unescape_blocks(jit_field(raw, fs[i+2], fe[i+2]))
    break
  }

  nmatch = 0; nnotice = 0
  if (ctx != "") {
    # The manifest-vs-fallback block split is shared with jit-dry-run.sh report_hook()
    # now (#223) -- jit_split_ctx_blocks() in common.sh (JIT_AWK_BLOCKS), carried over
    # verbatim from here rather than reimplemented, so the two consumers cannot drift the
    # way this one drifted out of step with #219 in the first place. It fills jit_blk_n
    # and jit_blk_body[1..jit_blk_n]; jit_index_verified() below is the second, structural
    # check this file still runs on top of it -- see its own comment for what it does and
    # does not close.
    jit_split_ctx_blocks(ctx)
    # #227: jit_blk_manifest_ok is set (0 or 1) by jit_split_ctx_blocks() above and was
    # read by nobody -- 0 means the manifest failed to verify and the split fell back to
    # the pre-#219/#223 heuristic splitter, which an entry body can forge. This tool must
    # never fail hard, so the degrade is named in the injected context instead of an
    # exception -- the same register the "N rule(s) could not be evaluated" notice
    # already uses (common.sh, jit_refusal_notice()) -- and it still counts as a notice
    # below, which already moves this tool off exit 0 the same way an unverifiable match
    # or a refused row does.
    #
    # Gated on !jit_blk_manifest_ok alone (#230): pre-prompt-hook.sh -- the only hook this
    # script ever shells out to -- always builds a manifest now, so "no manifest was ever
    if (!jit_blk_manifest_ok) {
      nnotice++
      notice[nnotice] = "# JIT Context: the block manifest could not be evaluated, so this call fell back to a splitter an entry body can forge"
    }
    nb = jit_blk_n
    for (b = 1; b <= nb; b++) {
      body = jit_blk_body[b]
      nl = index(body, "\n")
      header = (nl > 0) ? substr(body, 1, nl - 1) : body
      if (header !~ /^# Vocabulary: /) {
        nnotice++
        notice[nnotice] = body
        continue
      }
      mfile = header
      sub(/^# Vocabulary: /, "", mfile)
      sub(/ \(matched:.*$/, "", mfile)
      mkw = ""
      if (match(header, /\(matched: [^)]*\)/)) {
        mkw = substr(header, RSTART + 10, RLENGTH - 11)
        sub(/ \302\267 last edited [0-9]+d ago$/, "", mkw)
      }
      if (jit_index_verified(mfile, mkw)) {
        nmatch++
        mtext[nmatch] = body
        mname[nmatch] = mfile
        mkwlist[nmatch] = mkw
        mmode[nmatch] = (index(body, "\n[jit] Summary only") > 0) ? "summary" : "full"
      } else {
        nunverified++
        utext[nunverified] = body
        uname[nunverified] = mfile
        ukwlist[nunverified] = mkw
      }
    }
  }
  kept = nmatch
  dropped = 0
  if (limit > 0 && nmatch > limit) { kept = limit; dropped = nmatch - limit }
  if (format == "json") {
    out = "{\"count\":" nmatch ",\"dropped\":" dropped ",\"matches\":["
    for (m = 1; m <= kept; m++) {
      out = out (m > 1 ? "," : "") \
        "{\"file\":\"" emit_json_str(mname[m]) "\"" \
        ",\"keywords\":\"" emit_json_str(mkwlist[m]) "\"" \
        ",\"mode\":\"" mmode[m] "\"" \
        ",\"text\":\"" emit_json_str(mtext[m]) "\"}"
    }
    out = out "],\"dropped_files\":["
    for (m = kept + 1; m <= nmatch; m++) out = out (m > kept + 1 ? "," : "") "\"" emit_json_str(mname[m]) "\""
    out = out "],\"unverifiable\":["
    for (u = 1; u <= nunverified; u++) {
      out = out (u > 1 ? "," : "") \
        "{\"file\":\"" emit_json_str(uname[u]) "\"" \
        ",\"keywords\":\"" emit_json_str(ukwlist[u]) "\"" \
        ",\"text\":\"" emit_json_str(utext[u]) "\"}"
    }
    out = out "]}"
    print out
  } else {
    out = nmatch " entr" (nmatch == 1 ? "y" : "ies") " matched"
    if (dropped > 0) {
      out = out ", " dropped " dropped by --limit " limit ":"
      for (m = kept + 1; m <= nmatch; m++) out = out " " mname[m]
    }
    if (nunverified > 0) out = out ", " nunverified " unverifiable"
    print out
    for (m = 1; m <= kept; m++) print "\n---\n" mtext[m]
    if (nunverified > 0) {
      print "\n--- unverifiable (claimed file/keyword has no row in this tree own index -- NOT counted as a match) ---"
      for (u = 1; u <= nunverified; u++) print "\n" utext[u]
    }
    if (nnotice > 0) {
      print "\n--- notices (not counted as matches) ---"
      for (nt = 1; nt <= nnotice; nt++) print "\n" notice[nt]
    }
  }
  print "JIT-MATCH-STATUS\t" ((nnotice > 0 || nunverified > 0) ? 1 : 0)
}
'
)"

AWK_STATUS="$(printf '%s\n' "$RESULT" | awk -F'\t' '/^JIT-MATCH-STATUS\t/ { s = $2 } END { print s + 0 }')"
printf '%s\n' "$RESULT" | grep -v '^JIT-MATCH-STATUS'"$(printf '\t')"

EXIT=0
if [ "$HOOK_STDERR_CHECKED" = 1 ] && [ -n "$HOOK_STDERR" ]; then
  echo "" >&2
  echo "jit-match: NOTE -- pre-prompt-hook.sh wrote to stderr, which its own contract says" >&2
  echo "  it must never do. What matched above, if anything, is not the whole answer:" >&2
  printf '%s\n' "$HOOK_STDERR" | sed 's/^/  /' >&2
  EXIT=1
elif [ "$HOOK_STDERR_CHECKED" = 0 ]; then
  # Not promoted to exit 1: nothing was FOUND wrong, only left unverified, and jit-doctor.sh
  # already sets the precedent for that distinction -- its own "cannot tell" answers are
  # real, first-class outcomes that do not move an exit code, because a confident claim of
  # a defect that was never actually observed is worse than saying plainly it was not
  # checked. Always printed, on stderr, so this state is never silent either.
  echo "" >&2
  echo "jit-match: NOTE -- no temp file was available to check pre-prompt-hook.sh's stderr." >&2
  echo "  This is not a clean result: whether it kept its never-write-to-stderr contract" >&2
  echo "  was not checked, one way or the other. What matched above is not verified against it." >&2
fi
[ "$AWK_STATUS" = "1" ] && EXIT=1

exit "$EXIT"
