#!/bin/bash
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
  done < <(printf '%s\n' "$JIT_HOST_REGISTRY")
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
  local name sigs sig old_ifs
  while IFS='|' read -r name sigs _ _ _ _ _; do
    [ -n "$name" ] || continue
    [ -n "$sigs" ] || continue
    old_ifs="$IFS"
    IFS=','
    for sig in $sigs; do
      IFS="$old_ifs"
      if jit_host_sig_set "$sig"; then
        printf '%s\n' "$name"
        return 0
      fi
    done
    IFS="$old_ifs"
  done < <(printf '%s\n' "$JIT_HOST_REGISTRY")
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
  IFS='|' read -r _ _ _ _ _ _ refusal _ < <(printf '%s\n' "$row")
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
  done < <(printf '%s\n' "$JIT_HOST_REGISTRY")
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
jit_load_config() {
  local LC_ALL=C
  local file="$1" line cfg_name value reason q rest tail lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    while [ "$line" != "${line#[[:space:]]}" ]; do line="${line#[[:space:]]}"; done
    case "$line" in
      '' | '#'*) continue ;;
      export[[:space:]]*)
        line="${line#export}"
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
    if [ -z "$reason" ] && ! [[ "$cfg_name" =~ ^(JIT_CONTEXT|DYNAMIC_RULES|DVSI)_[A-Za-z0-9_]+$ ]]; then
      reason="unknown setting (only JIT_CONTEXT_*, DYNAMIC_RULES_* and DVSI_* are read)"
    fi
    if [ -n "$reason" ]; then
      jit_config_refuse "$lineno" "$reason"
      continue
    fi
    case "$value" in
      '"'* | "'"*)
        q="${value%"${value#?}"}" # the opening quote, " or '
        rest="${value#?}"
        case "$rest" in
          *"$q"*)
            tail="${rest#*"$q"}"
            while [ "$tail" != "${tail#[[:space:]]}" ]; do tail="${tail#[[:space:]]}"; done
            case "$tail" in
              '' | '#'*) value="${rest%%"$q"*}" ;;
              *) reason="trailing text after the closing quote" ;;
            esac
            ;;
          *) reason="unterminated quote" ;;
        esac
        ;;
      *)
        case "$value" in
          *[[:space:]]#*) value="${value%%[[:space:]]#*}" ;;
        esac
        while [ "$value" != "${value%[[:space:]]}" ]; do value="${value%[[:space:]]}"; done
        ;;
    esac
    if [ -n "$reason" ]; then
      jit_config_refuse "$lineno" "$reason"
      continue
    fi
    if [ "$cfg_name" = JIT_CONTEXT_INJECT ]; then
      case "$value" in
        summary | full) ;;
        *)
          jit_config_refuse "$lineno" "not an injection mode (the modes are summary and full)"
          continue
          ;;
      esac
    fi
    if [ "$cfg_name" = JIT_CONTEXT_STOP_REPORT ]; then
      case "$value" in
        0 | 1) ;;
        *)
          jit_config_refuse "$lineno" "not a stop-report toggle (0 or 1)"
          continue
          ;;
      esac
    fi
    if [ "$cfg_name" = JIT_CONTEXT_STATUS ]; then
      case "$value" in
        fired | summary | off) ;;
        *)
          jit_config_refuse "$lineno" "not a status mode (fired, summary or off)"
          continue
          ;;
      esac
    fi
    if [ "$cfg_name" = JIT_CONTEXT_MISSES ]; then
      case "$value" in
        on | off) ;;
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
function jit_entry_age(key,   raw, n, i, ln, tp) {
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
  if (key in jit_age) return jit_age[key]
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
function jit_entry_load(path, def, keepbody, e,   line, ln, nfm, want, key, val, nread, r) {
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
    key = substr(ln, 1, index(ln, ":") - 1)
    if (key ~ /[^A-Za-z0-9_-]/) continue
    val = substr(ln, index(ln, ":") + 1)
    sub(/^[[:space:]]+/, "", val)
    sub(/[[:space:]]+$/, "", val)
    if (val ~ /^"[^"]*"$/) val = substr(val, 2, length(val) - 2)
    if (key == "title") { if (e["title"] == "") e["title"] = val }
    else if (key == "description") { if (e["desc"] == "") e["desc"] = val }
    else if (key == "inject" && !e["injseen"]) {
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
      else if (c == "#") return 1
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
      else if (c == "#") break
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
function jit_hook_fields(raw, fs, fe, n, top_wanted, ti_wanted, TOP, TI,   depth, ti_depth, pending_key, pending_key_depth, i, c, ch, txt, val, nxt, is_key) {
  depth = 0
  ti_depth = -1
  pending_key = ""
  pending_key_depth = -1
  for (i = 1; i <= n; i++) {
    if (i % 2 == 1) {
      txt = raw[fs[i]]
      for (c = 1; c <= length(txt); c++) {
        ch = substr(txt, c, 1)
        if (ch == "{") {
          depth++
          if (pending_key == "tool_input" && pending_key_depth == 1 && ti_depth == -1) ti_depth = depth
        } else if (ch == "}") {
          if (depth == ti_depth) ti_depth = -1
          depth--
        }
      }
      continue
    }
    if (fs[i] != fe[i]) { pending_key = ""; pending_key_depth = -1; continue }
    val = raw[fs[i]]
    is_key = 0
    if (i + 1 <= n) {
      nxt = raw[fs[i+1]]
      if (nxt ~ /^[[:space:]]*:/) is_key = 1
    }
    if (!is_key) { pending_key = ""; pending_key_depth = -1; continue }
    pending_key = val
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
function jit_shown_mark(file, key) {
  if (file == "") return
  JIT_MARKS = JIT_MARKS file "\t" key "\n"
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
      if (hn == 3 + declared_n && declared_n >= 0 && hf[1] == "#" && hf[2] == "JIT-CTX-BLOCKS") {
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
JIT_MACRO_WRAP='(([a-z_][a-z0-9_]*=[^[:space:];&|]*|rtk|command|env|sudo|nohup|nice|time)[[:space:]]+)*'
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
jit_report_name() {
  local LC_ALL=C
  case "$1" in
    '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*)
      printf '%s' "$JIT_NAME_WITHHELD"
      return 0
      ;;
  esac
  [ "${#1}" -gt 64 ] && {
    printf '%s' "$JIT_NAME_WITHHELD"
    return 0
  }
  printf '%s' "$1"
}
export JIT_KEYWORD_WITHHELD='<withheld: not a plain keyword>'
jit_report_keyword() {
  local LC_ALL=C s="$1" flat rest n=1
  flat="${s// /-}"
  case "$flat" in
    '' | [!a-z0-9]* | *[!a-z0-9-]*)
      printf '%s' "$JIT_KEYWORD_WITHHELD"
      return 0
      ;;
  esac
  [ "${#s}" -gt 40 ] && {
    printf '%s' "$JIT_KEYWORD_WITHHELD"
    return 0
  }
  rest="$s"
  while [ "$rest" != "${rest#* }" ]; do
    rest="${rest#* }"
    n=$((n + 1))
  done
  [ "$n" -gt 4 ] && {
    printf '%s' "$JIT_KEYWORD_WITHHELD"
    return 0
  }
  printf '%s' "$s"
}
JIT_MISSING_REQUIRES_MAX=4096
BASE=""
BASE_FROM=""
usage() {
  printf '%s\n' \
    'jit-doctor.sh -- is any of this running at all, and against which tree?' \
    '' \
    '  jit-doctor [--base DIR]' \
    '' \
    '  --base DIR   the entry tree to judge. Default: $CLAUDE_PROJECT_DIR/.claude/jit-context,' \
    '               which is what the hooks read (with CLAUDE_PROJECT_DIR unset it falls' \
    '               back to the current directory).' \
    '  --help       this text.' \
    '' \
    'What it reports' \
    '' \
    '  tree         JIT_BASE as resolved, and what it resolved from' \
    '  hooks        which copy of the hooks would run -- the plugin cache, this checkout,' \
    '               BOTH, or `cannot tell`, which is a real answer and not a failure' \
    '  config.env   present or not, its refused lines, and the effective injection mode' \
    '  thresholds   the two ADVISORY thresholds and WHERE EACH CAME FROM, so a mistyped' \
    '               JIT_CONTEXT_DOCTOR_* key reads as a default rather than as a setting' \
    '  dimensions   per layer: entries, whether the matcher loads it, whether an index is' \
    '               there, and whether an entry is newer than it' \
    '  hook log     never ran, ran recently, or ran a while ago -- three states, not two' \
    '  advisory     short keywords, fat entries, entries with no record in the log' \
    '' \
    'Outcomes' \
    '' \
    '  ok, exit 0        nothing inert. ADVISORY findings do not move this.' \
    '  defect, exit 1    a layer holds entries and no index: those rules cannot fire.' \
    '  SKIPPED, exit 2   the tree could not be evaluated. The reason is named, on stderr.' \
    '' \
    'It reads and prints. It writes no entry and no index.'
}
need_value() {
  echo "jit-doctor: SKIPPED -- $1 needs a value" >&2
  echo "  run with --help for the accepted flags. Nothing was checked." >&2
  exit 2
}
if [ "${1:-}" = "--arguments-string" ]; then
  [ $# -ge 2 ] || need_value "$1"
  IFS=' ' read -r -a _jit_doctor_split_args < <(printf '%s\n' "${2:-}")
  shift 2
  set -- "${_jit_doctor_split_args[@]+"${_jit_doctor_split_args[@]}"}" "$@"
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ $# -ge 2 ] || need_value "$1"
      BASE="$2"
      BASE_FROM="--base on the command line"
      shift 2
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "jit-doctor: SKIPPED -- unknown argument: $1" >&2
      echo "  run with --help for the accepted flags. Nothing was checked." >&2
      exit 2
      ;;
  esac
done
if [ -z "$BASE" ]; then
  BASE="$JIT_BASE"
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    BASE_FROM="CLAUDE_PROJECT_DIR, which is set"
  else
    BASE_FROM="CLAUDE_PROJECT_DIR is unset, so it fell back to the current directory"
  fi
fi
BASE="${BASE%/}"
skip() {
  echo "jit-doctor: SKIPPED -- $1" >&2
  echo "  tree: $BASE" >&2
  echo "  Nothing was checked. This is not a clean result." >&2
  exit 2
}
[ -e "$BASE" ] || skip "no such directory -- this project has no entry tree, or it lives elsewhere (--base DIR)"
[ -d "$BASE" ] || skip "not a directory"
[ -r "$BASE" ] || skip "not readable"
HAVE_DIM=0
for _d in tools paths vocabulary; do
  [ -d "$BASE/$_d" ] && HAVE_DIM=1
done
unset _d
[ "$HAVE_DIM" = 1 ] || skip "no tools/, paths/ or vocabulary/ under it -- there is no entry tree here to judge"
DEFECTS=0
ADVISORY=""
ADVISORY_N=0
advise() {
  ADVISORY_N=$((ADVISORY_N + 1))
  ADVISORY="$ADVISORY  ADVISORY  $1
"
}
echo "jit-doctor -- is any of this running at all, and against which tree?"
echo ""
echo "tree"
printf '  %-20s %s\n' "JIT_BASE" "$BASE"
printf '  %-20s %s\n' "resolved from" "$BASE_FROM"
printf '  %-20s %s\n' "CLAUDE_PROJECT_DIR" "${CLAUDE_PROJECT_DIR:-(unset)}"
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  if ! command -v git > /dev/null 2>&1; then
    advise "cannot tell whether CLAUDE_PROJECT_DIR names a different git worktree than the one this shell is sitting in -- git is not on PATH, so this check (#402) could not run."
  else
    CWD_TOPLEVEL="$(git rev-parse --show-toplevel 2> /dev/null)"
    CPD_TOPLEVEL="$(cd "$CLAUDE_PROJECT_DIR" 2> /dev/null && git rev-parse --show-toplevel 2> /dev/null)"
    if [ -z "$CWD_TOPLEVEL" ] || [ -z "$CPD_TOPLEVEL" ]; then
      UNRESOLVED=""
      [ -z "$CWD_TOPLEVEL" ] && UNRESOLVED="the working directory"
      if [ -z "$CPD_TOPLEVEL" ]; then
        [ -n "$UNRESOLVED" ] && UNRESOLVED="$UNRESOLVED and "
        UNRESOLVED="${UNRESOLVED}CLAUDE_PROJECT_DIR ($CLAUDE_PROJECT_DIR)"
      fi
      advise "cannot tell whether CLAUDE_PROJECT_DIR names a different git worktree than the one this shell is sitting in -- $UNRESOLVED is not inside a git worktree git can resolve, so this check (#402) could not run."
    elif [ "$CWD_TOPLEVEL" != "$CPD_TOPLEVEL" ]; then
      advise "CLAUDE_PROJECT_DIR ($CLAUDE_PROJECT_DIR -- git worktree $CPD_TOPLEVEL) names a DIFFERENT git worktree than the one this shell is sitting in (git worktree $CWD_TOPLEVEL). Every hook resolves JIT_BASE from CLAUDE_PROJECT_DIR, never from the working directory -- an edit made in the tree you are sitting in can be served back from the OTHER tree copy of the same relative path, silently (#402)."
    fi
  fi
fi
echo ""
PROJ_DIR="$(cd "$BASE/../.." 2> /dev/null && pwd)" || PROJ_DIR=""
SETTINGS_SEEN=0
CACHE_SIDE=0
CHECKOUT_SIDE=0
SETTINGS_LIST=""
scan_settings() {
  local f="$1" enab hooksline cacheline
  [ -f "$f" ] && [ -r "$f" ] || return 0
  SETTINGS_SEEN=$((SETTINGS_SEEN + 1))
  SETTINGS_LIST="$SETTINGS_LIST  $(printf '%-20s %s\n' "scanned" "$f (textual scan, not a JSON parse)")
"
  enab=0
  if LC_ALL=C awk '/"enabledPlugins"[[:space:]]*:/ { found = 1 } END { exit !found }' "$f"; then
    enab=$(LC_ALL=C awk '/"(claude-)?jit-context(@[^"]*)?"[[:space:]]*:[[:space:]]*true/ { n++ } END { print n + 0 }' "$f")
  fi
  hooksline=$(LC_ALL=C awk '/(pre-prompt|pre-tool|pre-path|session-start)-hook[.]sh/ { n++ } END { print n + 0 }' "$f")
  cacheline=$(LC_ALL=C awk '/(pre-prompt|pre-tool|pre-path|session-start)-hook[.]sh/ && (/CLAUDE_PLUGIN_ROOT/ || /plugins\/cache/) { n++ } END { print n + 0 }' "$f")
  [ "$enab" -gt 0 ] && CACHE_SIDE=1
  [ "$cacheline" -gt 0 ] && CACHE_SIDE=1
  [ "$((hooksline - cacheline))" -gt 0 ] && CHECKOUT_SIDE=1
  return 0
}
if [ -n "$PROJ_DIR" ]; then
  scan_settings "$PROJ_DIR/.claude/settings.json"
  scan_settings "$PROJ_DIR/.claude/settings.local.json"
fi
[ -n "${HOME:-}" ] && scan_settings "$HOME/.claude/settings.json"
echo "hooks"
if [ "$CACHE_SIDE" = 1 ] && [ "$CHECKOUT_SIDE" = 1 ]; then
  printf '  %-20s %s\n' "which copy runs" "BOTH are registered -- a cache install and a hook command"
  printf '  %-20s %s\n' "" "both fire, and neither is silenced by editing the other"
elif [ "$CACHE_SIDE" = 1 ]; then
  printf '  %-20s %s\n' "which copy runs" "the plugin cache serves the hooks"
  printf '  %-20s %s\n' "" "so an edit to scripts/ in a checkout changes nothing in your session"
elif [ "$CHECKOUT_SIDE" = 1 ]; then
  printf '  %-20s %s\n' "which copy runs" "this checkout -- a hook command in settings names these scripts"
else
  printf '  %-20s %s\n' "which copy runs" "cannot tell"
  printf '  %-20s %s\n' "" "no settings file readable from here registers these hooks either way,"
  printf '  %-20s %s\n' "" "and Claude Code merges settings this script cannot see. Not a clean result."
fi
if [ "$SETTINGS_SEEN" -gt 0 ]; then
  printf '%s' "$SETTINGS_LIST"
else
  printf '  %-20s %s\n' "scanned" "no settings file at any location this textual scan can reach"
fi
plugin_version() {
  local pj="$1/.claude-plugin/plugin.json" v
  [ -r "$pj" ] || return 1
  v=$(LC_ALL=C awk '
    /"version"[[:space:]]*:/ {
      line = $0
      sub(/^.*"version"[[:space:]]*:[[:space:]]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }' "$pj")
  [ -n "$v" ] || return 1
  jit_report_name "$v"
  return 0
}
CACHE_HITS=""
CACHE_N=0
note_cache() {
  local root="$1" v
  [ -d "$root" ] || return 0
  v=$(plugin_version "$root") || v=""
  CACHE_N=$((CACHE_N + 1))
  CACHE_HITS="$CACHE_HITS  $(printf '%-20s %s\n' "plugin copy" "$root${v:+ (version $v)}")
"
}
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  note_cache "$CLAUDE_PLUGIN_ROOT"
fi
if [ -n "${HOME:-}" ]; then
  for _c in "$HOME"/.claude/plugins/cache/*/jit-context \
    "$HOME"/.claude/plugins/cache/*/jit-context/* \
    "$HOME"/.claude/plugins/cache/*/claude-jit-context \
    "$HOME"/.claude/plugins/cache/*/claude-jit-context/*; do
    [ -d "$_c/.claude-plugin" ] && note_cache "$_c"
  done
  unset _c
fi
if [ "$CACHE_N" = 0 ]; then
  printf '  %-20s %s\n' "plugin copy" "none found under \$HOME/.claude/plugins/cache -- so no version is claimed"
else
  printf '%s' "$CACHE_HITS"
  if [ "$CACHE_N" -gt 1 ]; then
    printf '  %-20s %s\n' "" "$CACHE_N copies are installed; which one loads is not decidable from here"
  fi
fi
echo ""
CFG="$BASE/config.env"
CFG_STATE=absent
CFG_REFUSED_N=0
TREE_INJECT=""
TREE_MAX=""
TREE_MIN=""
CFG_LINE_MAX=""
CFG_LINE_MIN=""
CFG_UNKNOWN=""
report_setting_name() {
  local LC_ALL=C
  case "$1" in
    '' | [!A-Za-z0-9]* | *[!A-Za-z0-9_]*)
      printf '%s' "<withheld: not a plain setting name>"
      return 0
      ;;
  esac
  [ "${#1}" -gt 64 ] && {
    printf '%s' "<withheld: not a plain setting name>"
    return 0
  }
  printf '%s' "$1"
}
if [ -L "$CFG" ]; then
  CFG_STATE="link"
elif [ -f "$CFG" ]; then
  CFG_STATE="present"
  _cfg=$(
    JIT_CONFIG_REFUSED=""
    JIT_CONFIG_REFUSED_N=0
    JIT_CONTEXT_INJECT=""
    JIT_CONTEXT_DOCTOR_MAX_BYTES=""
    JIT_CONTEXT_DOCTOR_MIN_KEYWORD=""
    jit_load_config "$CFG" > /dev/null 2>&1
    printf 'n=%s\n' "$JIT_CONFIG_REFUSED_N"
    printf 'inject=%s\n' "$JIT_CONTEXT_INJECT"
    printf 'max=%s\n' "$JIT_CONTEXT_DOCTOR_MAX_BYTES"
    printf 'min=%s\n' "$JIT_CONTEXT_DOCTOR_MIN_KEYWORD"
  )
  while IFS= read -r _l; do
    case "$_l" in
      n=*) CFG_REFUSED_N="${_l#n=}" ;;
      inject=*) TREE_INJECT="${_l#inject=}" ;;
      max=*) TREE_MAX="${_l#max=}" ;;
      min=*) TREE_MIN="${_l#min=}" ;;
    esac
  done < <(printf '%s\n' "$_cfg")
  case "$CFG_REFUSED_N" in '' | *[!0-9]*) CFG_REFUSED_N=0 ;; esac
  _n=0
  while IFS= read -r _l || [ -n "$_l" ]; do
    _n=$((_n + 1))
    _l="${_l%$'\r'}"
    while [ "$_l" != "${_l#[[:space:]]}" ]; do _l="${_l#[[:space:]]}"; done
    case "$_l" in
      '' | '#'*) continue ;;
      export[[:space:]]*)
        _l="${_l#export}"
        while [ "$_l" != "${_l#[[:space:]]}" ]; do _l="${_l#[[:space:]]}"; done
        ;;
    esac
    case "$_l" in *=*) _k="${_l%%=*}" ;; *) continue ;; esac
    case "$_k" in
      JIT_CONTEXT_DOCTOR_MAX_BYTES) CFG_LINE_MAX="$_n" ;;
      JIT_CONTEXT_DOCTOR_MIN_KEYWORD) CFG_LINE_MIN="$_n" ;;
      JIT_CONTEXT_DOCTOR_*)
        CFG_UNKNOWN="$CFG_UNKNOWN${CFG_UNKNOWN:+, }$(report_setting_name "$_k") (line $_n)"
        ;;
    esac
  done < "$CFG"
  unset _n _k _l _cfg
fi
echo "config.env"
case "$CFG_STATE" in
  absent) printf '  %-20s %s\n' "file" "absent -- every setting is at its default" ;;
  link) printf '  %-20s %s\n' "file" "a symbolic link, so the hooks do not read it at all" ;;
  present) printf '  %-20s %s\n' "file" "$CFG" ;;
esac
if [ "$CFG_STATE" = present ]; then
  if [ "$CFG_REFUSED_N" -gt 0 ]; then
    printf '  %-20s %s\n' "refused lines" "$CFG_REFUSED_N -- jit-dry-run.sh names which, by line number"
  else
    printf '  %-20s %s\n' "refused lines" "0 -- every line was honoured"
  fi
fi
case "$TREE_INJECT" in
  summary | full) printf '  %-20s %s\n' "JIT_CONTEXT_INJECT" "$TREE_INJECT (config.env)" ;;
  *) printf '  %-20s %s\n' "JIT_CONTEXT_INJECT" "full (default)" ;;
esac
echo ""
MAX_BYTES=4096
MAX_FROM="(default)"
MIN_KEYWORD=3
MIN_FROM="(default)"
THRESH_REFUSED=""
THRESH_VALUE=""
THRESH_FROM=""
read_threshold() {
  local raw="$1" line="$2" setting="$3"
  THRESH_VALUE=""
  THRESH_FROM=""
  [ -n "$raw" ] || return 1
  case "$raw" in
    '' | *[!0-9]*)
      THRESH_REFUSED="$THRESH_REFUSED  $(printf '%-20s %s' "" "$setting is not a whole number -- refused, the default stands")
"
      return 1
      ;;
  esac
  if [ "$raw" -lt 1 ]; then
    THRESH_REFUSED="$THRESH_REFUSED  $(printf '%-20s %s' "" "$setting is not a whole number above zero -- refused, the default stands")
"
    return 1
  fi
  THRESH_VALUE="$raw"
  THRESH_FROM="(config.env line ${line:-?})"
  return 0
}
if read_threshold "$TREE_MAX" "$CFG_LINE_MAX" "JIT_CONTEXT_DOCTOR_MAX_BYTES"; then
  MAX_BYTES="$THRESH_VALUE"
  MAX_FROM="$THRESH_FROM"
fi
if read_threshold "$TREE_MIN" "$CFG_LINE_MIN" "JIT_CONTEXT_DOCTOR_MIN_KEYWORD"; then
  MIN_KEYWORD="$THRESH_VALUE"
  MIN_FROM="$THRESH_FROM"
fi
echo "thresholds"
printf '  %-20s %s\n' "max entry bytes" "$MAX_BYTES $MAX_FROM"
printf '  %-20s %s\n' "min keyword bytes" "$MIN_KEYWORD $MIN_FROM"
[ -n "$THRESH_REFUSED" ] && printf '%s' "$THRESH_REFUSED"
if [ -n "$CFG_UNKNOWN" ]; then
  printf '  %-20s %s\n' "not read" "$CFG_UNKNOWN"
  printf '  %-20s %s\n' "" "config.env accepts any JIT_CONTEXT_* key; nothing reads these ones"
fi
echo ""
LOG="$BASE/.discovery/logs/hooks.log"
LOG_STATE=absent
LOG_RECORDS=0
LOG_AGE=""
if [ -f "$LOG" ] && [ -r "$LOG" ]; then
  LOG_STATE=present
  LOG_RECORDS=$(LC_ALL=C awk 'END { print NR + 0 }' "$LOG")
  if [ -n "$(find "$LOG" -prune 2> /dev/null)" ] && [ -z "$(find "$LOG" -prune -mtime +8192 2> /dev/null)" ]; then
    _age_lo=0
    _age_hi=8192
    while [ "$_age_lo" -lt "$_age_hi" ]; do
      _age_mid=$(((_age_lo + _age_hi) / 2))
      if [ -n "$(find "$LOG" -prune -mtime "+$_age_mid" 2> /dev/null)" ]; then
        _age_lo=$((_age_mid + 1))
      else
        _age_hi=$_age_mid
      fi
    done
    LOG_AGE=$_age_lo
    unset _age_lo _age_hi _age_mid
  fi
fi
echo "hook log"
if [ "$LOG_STATE" = absent ]; then
  printf '  %-20s %s\n' "state" "no hook log under this tree"
  printf '  %-20s %s\n' "" "the hooks have never run against it, or they ran against another one"
  printf '  %-20s %s\n' "expected at" "$LOG"
else
  printf '  %-20s %s\n' "file" "$LOG"
  printf '  %-20s %s\n' "records" "$LOG_RECORDS record(s)"
  if [ -z "$LOG_AGE" ]; then
    printf '  %-20s %s\n' "last written" "cannot tell -- the file's age could not be read"
  elif [ "$LOG_AGE" -lt 1 ]; then
    printf '  %-20s %s\n' "last written" "today"
  else
    printf '  %-20s %s\n' "last written" "$LOG_AGE days ago"
  fi
fi
echo ""
JIT_LAYERS_REFUSED=""
JIT_LAYERS_REFUSED_N=0
ENTRY_IDS=()
ENTRY_LABEL=()
ENTRY_NAME=()
ENTRY_BYTES=()
ENTRY_N=0
echo "dimensions"
for _dim in tools paths vocabulary; do
  if [ ! -d "$BASE/$_dim" ]; then
    printf '  %-24s %s\n' "$_dim/" "no such dimension directory"
    continue
  fi
  jit_scan_layers "$BASE/$_dim" "$_dim"
  _read=" $JIT_LAYERS "
  _rows=0
  for _d in "$BASE/$_dim"/*/; do
    [ -d "$_d" ] || continue
    _d="${_d%/}"
    _rows=$((_rows + 1))
    _layer="${_d##*/}"
    _safe="$(jit_report_name "$_layer")"
    _idx="$_d/00-index.tsv"
    _md_n=0
    _stale=0
    case "$_dim" in
      tools) _namecol=3 ;;
      *) _namecol=2 ;;
    esac
    _idx_names=""
    _idx_readable=1
    if [ -f "$_idx" ]; then
      if [ -r "$_idx" ]; then
        _idx_names="$(LC_ALL=C awk -F'\t' -v c="$_namecol" 'NF >= c { print $c }' "$_idx")"
      else
        _idx_readable=0
      fi
    fi
    for _md in "$_d"/*.md; do
      [ -f "$_md" ] || continue
      _md_n=$((_md_n + 1))
      [ -f "$_idx" ] && [ "$_md" -nt "$_idx" ] && _stale=1
      _name="${_md##*/}"
      if [ "$_idx_readable" = 1 ]; then
        case "$JIT_NL$_idx_names$JIT_NL" in
          *"$JIT_NL$_name$JIT_NL"*) : ;;
          *) continue ;;
        esac
      fi
      case "$_dim" in
        tools) _entry_id="tool:$_name" ;;
        *) _entry_id="$_layer:$_name" ;;
      esac
      case "$_entry_id" in *"$JIT_NL"*) _entry_id="<unnameable>" ;; esac
      ENTRY_IDS[$ENTRY_N]="$_entry_id"
      ENTRY_LABEL[$ENTRY_N]="$_dim/$_safe"
      ENTRY_NAME[$ENTRY_N]="$(jit_report_name "$_name")"
      ENTRY_BYTES[$ENTRY_N]=$(LC_ALL=C awk 'END { print n + 0 } { n += length($0) + 1 }' "$_md")
      ENTRY_N=$((ENTRY_N + 1))
    done
    _note=""
    if [ ! -f "$_idx" ]; then
      if [ "$_md_n" -gt 0 ]; then
        _note="no index -- every rule in this layer is inert, run the rebuild-tsv tool this plugin ships"
        DEFECTS=$((DEFECTS + 1))
      else
        _note="no index, and no entries either"
      fi
    elif [ "$_stale" = 1 ]; then
      _note="an entry is newer than the index -- see jit-dry-run.sh, which checks the rows"
      advise "$(printf '%-18s %-24s %s' "possibly inert" "$_dim/$_safe" "an entry is newer than the index")"
    else
      _note="index current"
    fi
    case "$_read" in
      *" $_layer "*) _loads="" ;;
      *) _loads="  NOT LOADED by the matcher" ;;
    esac
    printf '  %-24s %3d entr(y/ies)  %s%s\n' "$_dim/$_safe" "$_md_n" "$_note" "$_loads"
  done
  if [ "$_rows" = 0 ]; then
    printf '  %-24s %s\n' "$_dim/" "no layer directory under it -- there is nothing here to load"
  fi
done
unset _dim _d _layer _safe _idx _md _md_n _stale _name _key _note _loads _read _rows
if [ "$JIT_LAYERS_REFUSED_N" -gt 0 ]; then
  printf '  %s\n' "$JIT_LAYERS_REFUSED_N layer director(y/ies) exist and the matcher does not read:"
  printf '%s\n' "$JIT_LAYERS_REFUSED" | sed 's/^/    /'
  printf '  %s\n' "Nothing inside them can fire. jit-dry-run.sh prints the same list with its lint."
fi
echo ""
FIRED=()
if [ "$LOG_STATE" = present ] && [ "$ENTRY_N" -gt 0 ]; then
  _counts=$(printf '%s\n' "${ENTRY_IDS[@]}" | LC_ALL=C awk '
    FNR == NR { order[++nk] = $0; next }
    {
      p = index($0, " | ")
      if (p == 0) next
      rest = substr($0, p + 3)
      q = index(rest, sprintf(" %c%c ", 60, 60))
      if (q > 0) rest = substr(rest, 1, q - 1)
      n = split(rest, items, ", ")
      for (i = 1; i <= n; i++) {
        b = index(items[i], "(")
        if (b < 2) continue
        cnt[substr(items[i], 1, b - 1)]++
      }
    }
    END { for (j = 1; j <= nk; j++) print (order[j] in cnt) ? cnt[order[j]] : 0 }
  ' - "$LOG")
  _i=0
  while IFS= read -r _c; do
    FIRED[$_i]="$_c"
    _i=$((_i + 1))
  done < <(printf '%s\n' "$_counts")
  unset _counts _i _c
fi
_i=0
while [ "$_i" -lt "$ENTRY_N" ]; do
  _b="${ENTRY_BYTES[$_i]}"
  if [ "$_b" -gt "$MAX_BYTES" ]; then
    if [ "$LOG_STATE" = present ] && [ "${#FIRED[@]}" -gt "$_i" ]; then
      _f=", fired ${FIRED[$_i]}x in this log"
    else
      _f=""
    fi
    advise "$(printf '%-18s %-24s %s' "fat entry" "${ENTRY_LABEL[$_i]}" "${ENTRY_NAME[$_i]} is over $MAX_BYTES bytes ($_b)$_f")"
  fi
  _i=$((_i + 1))
done
if [ "$LOG_STATE" = present ]; then
  _i=0
  while [ "$_i" -lt "$ENTRY_N" ]; do
    if [ "${#FIRED[@]}" -gt "$_i" ] && [ "${FIRED[$_i]}" = 0 ]; then
      advise "$(printf '%-18s %-24s %s' "never fired" "${ENTRY_LABEL[$_i]}" "${ENTRY_NAME[$_i]}: no record in the log")"
    fi
    _i=$((_i + 1))
  done
fi
unset _i _b _f
scan_short_keywords() {
  local LC_ALL=C dim=vocabulary d safe row kw ent
  [ -d "$BASE/$dim" ] || return 0
  for d in "$BASE/$dim"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    safe="$(jit_report_name "${d##*/}")"
    [ -f "$d/00-index.tsv" ] && [ -r "$d/00-index.tsv" ] || continue
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      kw="${row%%	*}"
      ent="${row#*	}"
      ent="${ent%%	*}"
      [ "${#kw}" -lt "$MIN_KEYWORD" ] || continue
      advise "$(printf '%-18s %-24s %s' "short keyword" "$dim/$safe" "$(jit_report_name "$ent"): keyword '$(jit_report_keyword "$kw")' is ${#kw} bytes, minimum $MIN_KEYWORD")"
    done < <(LC_ALL=C awk 'NF { print }' "$d/00-index.tsv")
  done
  return 0
}
scan_short_keywords
echo "advisory (none of this moves the exit code)"
if [ "$ADVISORY_N" = 0 ]; then
  printf '  %s\n' "0 advisory notes -- nothing flagged on this tree"
else
  printf '%s' "$ADVISORY"
  printf '  %s\n' "$ADVISORY_N advisory note(s), and none of them changed the status below"
fi
echo ""
echo "next"
printf '  %s\n' "jit-dry-run --base $BASE"
printf '  %s\n' "    the pattern lint and the exact staleness check -- a rule the matcher cannot"
printf '  %s\n' "    honour, and frontmatter the index does not carry. This tool reimplements"
printf '  %s\n' "    neither of them, on purpose: two answers to one question drift."
echo ""
if [ "$DEFECTS" -gt 0 ]; then
  echo "jit-doctor: $DEFECTS defect(s) -- a layer holds entries the matcher can never load."
  exit 1
fi
echo "jit-doctor: ok -- nothing inert. See the advisory section above; it did not change this."
exit 0
