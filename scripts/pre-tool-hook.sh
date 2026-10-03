#!/bin/bash
_ms() {
  local e="${EPOCHREALTIME:-}" s f
  case "$e" in
    *[.,]*)
      s="${e%%[.,]*}"
      f="${e##*[.,]}000000"
      f="${f:0:6}"
      case "$s$f" in
        '' | *[!0-9]*) ;;
        *)
          printf '%s\n' "$((s * 1000 + 10#$f / 1000))"
          return
          ;;
      esac
      ;;
  esac
  perl -MTime::HiRes -e 'printf("%.0f\n",Time::HiRes::time()*1000)'
}
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  JIT_BASE="$CLAUDE_PROJECT_DIR/.claude/jit-context"
else
  JIT_BASE="$(pwd)/.claude/jit-context"
fi
export JIT_BASE
jit_worktree_mismatch_line() {
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] || return 0
  command -v git > /dev/null 2>&1 || return 0
  local pwd_top cpd_top
  pwd_top="$(git rev-parse --show-toplevel 2> /dev/null)"
  cpd_top="$(cd "$CLAUDE_PROJECT_DIR" 2> /dev/null && git rev-parse --show-toplevel 2> /dev/null)"
  [ -n "$pwd_top" ] || return 0
  [ -n "$cpd_top" ] || return 0
  [ "$pwd_top" != "$cpd_top" ] || return 0
  printf '%s' "CLAUDE_PROJECT_DIR ($CLAUDE_PROJECT_DIR -- git worktree $cpd_top) names a DIFFERENT git worktree than the one this shell is sitting in (\$PWD ($PWD) -- git worktree $pwd_top)."
}
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
jit_marks_read() {
  local line
  JIT_MARKS_IN=()
  JIT_MARKS_OK=0
  while IFS= read -r line; do
    if [ "$line" = "$JIT_MARK_END" ]; then
      JIT_MARKS_OK=1
      return 0
    fi
    JIT_MARKS_IN[${#JIT_MARKS_IN[@]}]="$line"
  done
  return 0
}
jit_shown_apply() {
  local f k name entry
  [ -n "$JIT_STATE_DIR" ] || return 0
  [ "$JIT_MARKS_OK" = 1 ] || return 0
  [ "${#JIT_MARKS_IN[@]}" -gt 0 ] || return 0
  for entry in "${JIT_MARKS_IN[@]}"; do
    f="${entry%%$'\t'*}"
    k="${entry#*$'\t'}"
    [ "$k" != "$entry" ] || continue
    [ -n "$f" ] && [ -n "$k" ] || continue
    name="${f#"$JIT_STATE_DIR"/}"
    [ "$name" != "$f" ] || continue
    case "$name" in
      */*) continue ;;
      *\\*) continue ;;
      path-shown-*.txt | vocab-shown-*.txt | bytes-shown-*.txt) ;;
      *) continue ;;
    esac
    [ -L "$f" ] && continue
    printf '%s\n' "$k" 2> /dev/null >> "$f"
  done
  return 0
}
JIT_TMP=""
jit_tmp_open() {
  local d
  d="${TMPDIR:-/tmp}"
  d="${d%/}"
  JIT_TMP="$(mktemp "$d/claude-jit-XXXXXXXX" 2> /dev/null)" || JIT_TMP=""
  [ -n "$JIT_TMP" ] || return 0
  trap 'rm -f "$JIT_TMP"' EXIT
  return 0
}
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
_log_hook() {
  local LC_ALL=C
  local hook="$1"
  local ms="$2"
  local matches="${3:-(none)}"
  local tail="${4:-}"
  local dropped head
  if [ "${#matches}" -gt "$JIT_LOG_MATCHES_MAX" ]; then
    head="${matches:0:$JIT_LOG_MATCHES_MAX}"
    case "$head" in *", "*) head="${head%, *}, " ;; esac
    dropped=$((${#matches} - ${#head}))
    matches="${head}[+$dropped bytes not listed here, and the item before this marker may be a fragment; this line is capped at ${JIT_LOG_MATCHES_MAX} bytes -- the jit-dry-run tool prints the whole tree]"
  fi
  jit_log_write "[$(_ts)] $hook ${ms}ms | $matches${tail:+ $tail}"
}
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
jit_scan_entry_ages() {
  local base="$1" layer d out
  local LC_ALL=C
  JIT_ENTRY_AGES=""
  local window="${JIT_CONTEXT_CHECKOUT_WINDOW_S:-${DYNAMIC_RULES_CHECKOUT_WINDOW_S:-5}}"
  case "$window" in '' | *[!0-9]*) window=5 ;; esac
  for layer in $JIT_LAYERS; do
    case "$layer" in
      *00-manual*) ;;
      *) continue ;;
    esac
    d="$base/$layer"
    [ -d "$d" ] || continue
    out="$(perl -e '
      my $d = shift or exit 0;
      opendir(my $h, $d) or exit 0;
      while (defined(my $e = readdir $h)) {
        next if $e eq "." || $e eq "..";
        # A tab or a newline in the filename would land inside the very bytes this
        # table uses as its own field and record separators, and jit_entry_age() (the
        # awk half) has no way to tell "a filename that happens to contain a tab" from
        # a genuine second row -- it would either fold two files onto the one key that
        # stops at the first tab, or split one row into two. Refused here, before
        # either byte ever reaches the table, rather than tolerated downstream.
        next if $e =~ /[\t\n]/;
        my $f = "$d/$e";
        next if -l $f;
        next unless -f $f;
        my $days = int(-M $f);
        $days = 0 if $days < 0;
        my $mtime = (stat($f))[9];
        print "$e\t$days\t$mtime\n";
      }
      closedir $h;
    ' "$d" 2> /dev/null)"
    [ -n "$out" ] || continue
    local n=0 emin="" emax=""
    while IFS=$'\t' read -r _e _days epoch; do
      [ -n "$epoch" ] || continue
      n=$((n + 1))
      if [ -z "$emin" ] || [ "$epoch" -lt "$emin" ]; then emin="$epoch"; fi
      if [ -z "$emax" ] || [ "$epoch" -gt "$emax" ]; then emax="$epoch"; fi
    done < <(printf '%s\n' "$out")
    if [ "$n" -ge 2 ] && [ -n "$emin" ] && [ -n "$emax" ] && [ $((emax - emin)) -le "$window" ]; then
      jit_log_write "[$(_ts)] entry-ages declined for $layer: $n files within $((emax - emin))s of each other (looks like a checkout, not real age data)"
      continue
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      line="${line%$'\t'*}"
      if [ "${#JIT_ENTRY_AGES}" -gt "$JIT_ENTRY_AGES_MAX" ]; then
        continue
      fi
      JIT_ENTRY_AGES="$JIT_ENTRY_AGES${JIT_ENTRY_AGES:+$JIT_NL}$layer/$line"
    done < <(printf '%s\n' "$out")
  done
}
export JIT_KEYWORD_WITHHELD='<withheld: not a plain keyword>'
JIT_MISSING_REQUIRES_MAX=4096
jit_missing_requires() {
  local base="$1" layers="$2" layer tsv bin seen=" " missing=" " cut=0
  local LC_ALL=C
  for layer in $layers; do
    tsv="$base/$layer/00-index.tsv"
    [ -f "$tsv" ] || continue
    while IFS= read -r bin; do
      [ -z "$bin" ] && continue
      case "$bin" in
        *[!A-Za-z0-9._+-]*) continue ;;
      esac
      [ "${#bin}" -gt 255 ] && continue
      case "$seen" in *" $bin "*) continue ;; esac
      seen="$seen$bin "
      command -v -- "$bin" > /dev/null 2>&1 && continue
      if [ "${#missing}" -gt "$JIT_MISSING_REQUIRES_MAX" ]; then
        if [ "$cut" = 0 ]; then
          cut=1
          missing="${missing}[JIT-427:list-truncated-at-cap] "
        fi
        continue
      fi
      missing="$missing$bin "
    done < <(LC_ALL=C awk -F "$(printf '\t')" '{ print (NF >= 7) ? $7 : "" }' "$tsv")
  done
  printf '%s' "$missing"
}
jit_awk_capture() {
  local d f urc
  d="${TMPDIR:-/tmp}"
  d="${d%/}"
  f="$(mktemp "$d/claude-jit-awkout-XXXXXXXX" 2> /dev/null)" || f=""
  if [ -z "$f" ]; then
    LC_ALL=C "$@"
    urc=$?
    JIT_AWK_CAPTURE_OUT=""
    if [ "$urc" -gt 128 ] 2> /dev/null; then
      JIT_AWK_CAPTURE_RC=$urc
    else
      JIT_AWK_CAPTURE_RC="uncaptured"
    fi
    return 0
  fi
  LC_ALL=C "$@" > "$f"
  JIT_AWK_CAPTURE_RC=$?
  IFS= read -r -d '' JIT_AWK_CAPTURE_OUT < "$f"
  rm -f "$f"
}
jit_awk_crash_block() {
  local rc="${1:-?}"
  printf "{\"decision\":\"block\",\"reason\":\"# JIT Context: the rule engine could not evaluate this call -- awk exited %s before it finished. Refusing rather than permitting a call no rule was actually checked against. See issue #397.\"}" "$rc"
}
jit_awk_crash_sysmsg() {
  local rc="${1:-?}"
  printf "{\"systemMessage\":\"JIT Context: the rule engine could not evaluate this turn -- awk exited %s before it finished. No entries were checked, so none were injected. See issue #397.\"}" "$rc"
}
jit_awk_empty_ok() {
  printf '{}\n'
}
jit_awk_dispatch() {
  local crash_fn="$1" empty_fn="$2"
  if [ "$JIT_AWK_CAPTURE_RC" = "uncaptured" ]; then
    return 0
  fi
  if [ "$JIT_AWK_CAPTURE_RC" -eq 0 ] 2> /dev/null; then
    printf '%s' "$JIT_AWK_CAPTURE_OUT"
  elif [ "$JIT_AWK_CAPTURE_RC" -gt 128 ] 2> /dev/null; then
    _jit_awk_handler "$crash_fn" "$JIT_AWK_CAPTURE_RC"
  elif [ -n "$JIT_AWK_CAPTURE_OUT" ]; then
    printf '%s' "$JIT_AWK_CAPTURE_OUT"
  else
    _jit_awk_handler "$empty_fn" "$JIT_AWK_CAPTURE_RC"
  fi
}
_jit_awk_handler() {
  case "$1" in
    jit_path_awk_could_not_evaluate) jit_path_awk_could_not_evaluate "$2" ;;
    jit_path_awk_ordinary_empty) jit_path_awk_ordinary_empty "$2" ;;
    jit_awk_crash_sysmsg) jit_awk_crash_sysmsg "$2" ;;
    jit_awk_empty_ok) jit_awk_empty_ok "$2" ;;
    jit_awk_crash_block) jit_awk_crash_block "$2" ;;
    *) return 127 ;;
  esac
}
T_START=$(_ms)
jit_tmp_open
jit_scan_layers "$JIT_BASE/tools" tools
JIT_TOOL_LAYERS="$JIT_LAYERS"
jit_scan_layers "$JIT_BASE/vocabulary" vocabulary
jit_scan_entry_ages "$JIT_BASE/vocabulary"
JIT_VOCAB_LAYERS="$JIT_LAYERS"
JIT_MISSING_REQUIRES="$(jit_missing_requires "$JIT_BASE/tools" "$JIT_TOOL_LAYERS")"
JIT_WORKTREE_NOTE="$(jit_worktree_mismatch_line)"
export JIT_WORKTREE_NOTE
JIT_AWK_ARGS=(
  -v tool_layers="$JIT_TOOL_LAYERS"
  -v tool_aliases="$JIT_TOOL_ALIASES"
  -v vocab_layers="$JIT_VOCAB_LAYERS"
  -v state_dir="$JIT_STATE_DIR"
  -v inject_default="$JIT_INJECT"
  -v log_tmp="$JIT_TMP"
  -v missing_bins="$JIT_MISSING_REQUIRES"
  -v status_mode="$JIT_STATUS"
)
JIT_AWK_PROGRAM="$JIT_AWK_GUARD$JIT_AWK_ENTRY$JIT_AWK_INJECT$JIT_AWK_JSON$JIT_AWK_FOLD$JIT_AWK_HEREDOC$JIT_AWK_BLK_BUILD$JIT_AWK_ENVELOPE$JIT_AWK_ENVELOPE_SYSMSG"'
function jit_json_escape(s,   k, c) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s)
  gsub(/\n/, "\\n", s)
  gsub(/\r/, "\\r", s)
  for (k = 0; k <= 31; k++) {
    if (k == 9 || k == 10 || k == 13) continue
    c = sprintf("%c", k)
    if (length(c) == 0) continue
    if (index(s, c) > 0) gsub(c, sprintf("\\u%04x", k), s)
  }
  return s
}
function jit_re_lit(s,    i, c, out, special) {
  special = "\\.^$*+?()[]{}|"
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    out = out (index(special, c) > 0 ? "\\" c : c)
  }
  return out
}
function jit_expand_tool_alias(aliases, raw,    n, entries, i, eq, key) {
  if (aliases == "" || raw == "") return raw
  n = split(aliases, entries, ",")
  for (i = 1; i <= n; i++) {
    eq = index(entries[i], "=")
    if (eq == 0) continue
    key = substr(entries[i], 1, eq - 1)
    if (key != raw) continue
    gsub(/;/, " ", entries[i])
    return raw " " substr(entries[i], eq + 1)  # union, not replace (#364)
  }
  return raw
}
{ input = input $0 }
END {
  n = jit_json_fields(input, raw, fs, fe)
  shown_file = jit_shown_file(state_dir, "vocab", raw, fs, fe, n)
  bytes_shown_file = jit_shown_file(state_dir, "bytes", raw, fs, fe, n)
  agent_shown_file = jit_agent_shown_file(state_dir, "vocab", raw, fs, fe, n)
  top_wanted["tool_name"] = 1
  ti_wanted["command"] = 1
  ti_wanted["skill"] = 1
  ti_wanted["file_path"] = 1
  ti_wanted["pattern"] = 1
  ti_wanted["subagent_type"] = 1
  jit_hook_fields(raw, fs, fe, n, top_wanted, ti_wanted, TOP, TI)
  tool_name = TOP["tool_name"]
  command = TI["command"]
  f_skill = TI["skill"]
  f_file_path = TI["file_path"]
  f_pattern = TI["pattern"]
  f_subagent = TI["subagent_type"]
  full_command = command
  if (full_command == "") full_command = f_skill
  if (full_command == "") full_command = f_file_path
  if (full_command == "") full_command = f_pattern
  if (full_command == "") full_command = f_subagent
  cmd = full_command
  gsub(/[;&|].*/, "", cmd)
  q = index(cmd, "\"")
  if (q > 0) cmd = substr(cmd, 1, q - 1)
  gsub(/ --.*/, "", cmd)
  probe = cmd
  gsub(/[[:space:]]/, "", probe)
  if (probe == "") cmd = ""
  if (tool_name == "") { print "{}"; exit }
  n_tool_variants = split(jit_expand_tool_alias(tool_aliases, tool_name), tool_variants, " ")
  no_subject = (full_command == "")
  fold_cmd = jit_fold_latin1(tolower(cmd))
  fold_full = jit_fold_latin1(tolower(jit_strip_heredoc_body(full_command, 0)))
  fold_full_req = jit_fold_latin1(tolower(jit_strip_heredoc_body(full_command, 1)))
  nblk = 0
  blocked = ""
  sys_msg = ""
  sys_msg_block_file = ""
  log_matches = ""
  sep = ""
  refused = ""
  n_refused = 0
  unreached = ""
  n_unreached = 0
  jit_shown_load(shown_file, shown)
  if (agent_shown_file == shown_file) {
    for (jak in shown) agent_shown[jak] = 1
  } else {
    jit_shown_load(agent_shown_file, agent_shown)
  }
  n_tool_layers = split(tool_layers, tlayers, " ")
  for (tli = 1; tli <= n_tool_layers; tli++) {
    tool_layer = tlayers[tli]
    tool_label = "tools/" tool_layer
    tools_tsv = ENVIRON["JIT_BASE"] "/tools/" tool_layer "/00-index.tsv"
    tools_dir = ENVIRON["JIT_BASE"] "/tools/" tool_layer
    rown = 0
    while ((getline tline < tools_tsv) > 0) {
      rown++
      split(tline, tf, "\t")
      r_tool = tf[1]; r_match = tf[2]; r_file = tf[3]
      r_modes = tf[4]; r_require = tf[5]; r_forbid = tf[6]; r_requires = tf[7]
      r_kind = (index(r_modes, "block") > 0) ? " (a block rule)" : ""
      requires_missing = (r_requires != "" && index(missing_bins, " " r_requires " ") > 0)
      would_refuse = (index(r_modes, "block") > 0 || r_require != "" || r_forbid != "")
      can_refuse = would_refuse && !requires_missing
      why = jit_bad_bytes(tline, "the index row")
      if (why != "") {
        n_refused++
        refused = jit_refuse_add(refused, jit_row_id(tool_label, rown) r_kind ": " why)
        log_matches = log_matches sep "refused:" jit_row_id(tool_label, rown) "(" why ")"
        sep = ", "
        continue
      }
      file_why = jit_bad_entry_file(r_file, tools_dir)
      if (file_why != "") {
        n_refused++
        refused = jit_refuse_add(refused, jit_row_id(tool_label, rown) r_kind ": " file_why)
        log_matches = log_matches sep "refused:" jit_log_name(r_file, tool_label, rown, file_why) "(" file_why ")"
        sep = ", "
        if (!can_refuse) continue
      }
      r_logname = (file_why != "") ? jit_log_name(r_file, tool_label, rown, file_why) : r_file
      r_header_name = (file_why != "") ? jit_row_id(tool_label, rown) : r_file
      tool_hit = 0
      nt = split(r_tool, talts, "|")
      for (ti = 1; ti <= nt && !tool_hit; ti++) {
        for (tvi = 1; tvi <= n_tool_variants; tvi++) {
          if (talts[ti] == tool_variants[tvi]) { tool_hit = 1; break }
        }
      }
      if (!tool_hit) continue
      if (no_subject) {
        n_unreached++
        unreached = jit_unreached_add(unreached, jit_row_id(tool_label, rown) r_kind)
        log_matches = log_matches sep "nosubject:" jit_row_id(tool_label, rown)
        sep = ", "
        continue
      }
      if (substr(r_match, 1, 1) == "~") {
        why = jit_bad_pattern(substr(r_match, 2))
        if (why != "") {
          n_refused++
          refused = jit_refuse_add(refused, jit_row_id(tool_label, rown) r_kind ": " why)
          log_matches = log_matches sep "refused:" r_file "(" why ")"
          sep = ", "
          continue
        }
        if (match(fold_full, jit_fold_latin1(substr(r_match, 2))) == 0) continue
      } else {
        if (index(fold_cmd, jit_fold_latin1(tolower(r_match))) == 0) continue
      }
      key = ""
      hushed = 0
      if (index(r_modes, "once") > 0) {
        key = jit_loc_key("tools", tool_layer, r_file)
        if ((key in agent_shown) || (key in held)) {
          if (!can_refuse) continue
          hushed = 1
        }
      }
      keepbody = can_refuse
      content = ""
      body = ""
      why = ""
      if (file_why != "") {
        body = "(the text of this rule was not delivered: " file_why ")"
        key = ""
      } else {
        rpath = tools_dir "/" r_file
        if (jit_entry_load(rpath, inject_default, keepbody, ent)) {
          body = ent["body"]
          content = jit_inject_text(ent, ".claude/jit-context/" tool_label "/" r_file, rpath)
        }
        why = ent["why"]
      }
      if (why != "") {
        body = "(the text of this rule was not delivered: " why ")"
        content = body
        n_refused++
        refused = jit_refuse_add(refused, jit_row_id(tool_label, rown) r_kind ": " why)
        log_matches = log_matches sep "refused:" jit_log_name(r_file, tool_label, rown, why) "(" why ")"
        sep = ", "
        key = ""
      }
      if (keepbody && body ~ /^[[:space:]]*$/) {
        body = "(the text of this rule was not delivered: the entry file has no text)"
        key = ""
      }
      if (requires_missing && would_refuse) {
        degrade_note = "[jit] This rule would normally refuse this call, but `" r_requires "` was not found on PATH, so it has degraded to advisory instead of blocking. Install `" r_requires "` to restore enforcement."
        content = (content == "") ? degrade_note : degrade_note "\n" content
      }
      if (r_require != "" && !requires_missing) {
        nr = split(r_require, reqs, "|")
        for (ri = 1; ri <= nr; ri++) {
          if (index(fold_full_req, jit_fold_latin1(tolower(reqs[ri]))) == 0) {
            blocked = "BLOCKED: Missing required: " reqs[ri] ". " body
            if (status_mode == "fired") sys_msg_block_file = "tools/" tool_layer "/" r_file
            log_matches = log_matches sep "tool:" r_logname "(BLOCKED:" reqs[ri] ")"
            sep = ", "
            break
          }
        }
        if (blocked != "") break
      }
      if (r_forbid != "" && blocked == "" && !requires_missing) {
        nfb = split(r_forbid, forbs, "|")
        for (fi = 1; fi <= nfb; fi++) {
          if (index(fold_full, jit_fold_latin1(tolower(forbs[fi]))) > 0) {
            blocked = "BLOCKED: Forbidden: " forbs[fi] ". " body
            if (status_mode == "fired") sys_msg_block_file = "tools/" tool_layer "/" r_file
            log_matches = log_matches sep "tool:" r_logname "(BLOCKED:" forbs[fi] ")"
            sep = ", "
            break
          }
        }
        if (blocked != "") break
      }
      header = "# JIT Context: " r_header_name " (matched: " r_match ")"
      if (index(r_modes, "block") > 0 && !requires_missing && blocked == "") {
        log_matches = log_matches sep "tool:" r_logname "(" r_match ")[full:block]"
        sep = ", "
        blocked = header "\n" body
        if (status_mode == "fired") sys_msg_block_file = "tools/" tool_layer "/" r_file
        break
      }
      if (content != "" && blocked == "" && !hushed) {
        log_adv = log_adv asep "tool:" r_logname "(" r_match ")" jit_inject_tag(ent)
        asep = ", "
        if (key != "") { held[key] = 1; hold_n++ }
        if (ent["mode"] == "full" && why == "" && body !~ /^[[:space:]]*$/) adv_header = header
        else adv_header = "# JIT Context: " jit_clip(r_header_name, 255) " (matched: " jit_clip(r_match, 160) ")"
        nblk++; blk[nblk] = adv_header "\n" content
        if (key != "") held_bytes[key] = length(adv_header "\n" content)
        if (status_mode == "fired") sys_msg = sys_msg (sys_msg != "" ? "\n" : "") "JIT : tools/" tool_layer "/" r_file " (" jit_fmt_bytes(length(adv_header "\n" content)) ")"
      }
    }
    close(tools_tsv)
    if (blocked != "") break
  }
  if (hold_n > 0 && blocked == "") {
    for (hk in held) {
      shown[hk] = 1
      jit_shown_mark(shown_file, hk)
      agent_shown[hk] = 1
      if (agent_shown_file != shown_file) jit_shown_mark(agent_shown_file, hk)
      if (hk in held_bytes) jit_shown_mark(bytes_shown_file, hk "\t" held_bytes[hk])
    }
  }
  if (log_adv != "") {
    if (blocked == "") { log_matches = log_matches sep log_adv; sep = ", " }
    else { withheld_log = log_adv; wsep = ", " }
  }
  cmd_paths = ""
  np = split(command, ptoks, /[[:space:]]+/)
  for (pi = 1; pi <= np; pi++) {
    if (index(ptoks[pi], "/") > 0) cmd_paths = cmd_paths " " ptoks[pi]
  }
  tt = f_file_path " " cmd_paths
  home = ENVIRON["HOME"]
  project = (ENVIRON["CLAUDE_PROJECT_DIR"] != "" ? ENVIRON["CLAUDE_PROJECT_DIR"] : ".")
  if (home != "") gsub(jit_re_lit(home) "/", "", tt)
  gsub(jit_re_lit(project) "/", "", tt)
  cc = ""
  for (i = 1; i <= length(tt); i++) {
    c = substr(tt, i, 1)
    p = (i > 1) ? substr(tt, i-1, 1) : ""
    if (c != "" && p != "" && index("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c) > 0 && index("abcdefghijklmnopqrstuvwxyz0123456789", p) > 0) cc = cc " " c
    else cc = cc c
  }
  tt = tolower(cc)
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", tt)
  low = " " tt " "
  padded = jit_fold_latin1(low)
  stale = (padded != low) ? low : ""
  gsub(/[^a-z0-9 -]/, " ", padded)
  gsub(/  +/, " ", padded)
  if (stale != "") {
    gsub(/[^a-z0-9 -]/, " ", stale)
    gsub(/  +/, " ", stale)
  }
  if (tt != "" && !no_subject) {
    n_vocab_layers = split(vocab_layers, layers, " ")
    for (li = 1; li <= n_vocab_layers; li++) {
      layer = layers[li]
      lookup = ENVIRON["JIT_BASE"] "/vocabulary/" layer "/00-index.tsv"
      delete vmatch
      delete vmrow
      delete vspecific
      vrown = 0
      while ((getline vl < lookup) > 0) {
        vrown++
        why = jit_bad_bytes(vl, "the index row")
        if (why != "") {
          n_refused++
          refused = jit_refuse_add(refused, jit_row_id("vocabulary/" layer, vrown) ": " why)
          log_matches = log_matches sep "refused:" jit_row_id("vocabulary/" layer, vrown) "(" why ")"
          sep = ", "
          continue
        }
        split(vl, vf, "\t")
        kw = vf[1]; vfile = vf[2]; kwverdict = vf[3]
        why = jit_bad_entry_file(vfile, ENVIRON["JIT_BASE"] "/vocabulary/" layer)
        if (why != "") {
          if (!((layer "/" vfile) in vrefused)) {
            vrefused[layer "/" vfile] = 1
            n_refused++
            refused = jit_refuse_add(refused, jit_row_id("vocabulary/" layer, vrown) ": " why)
            log_matches = log_matches sep "refused:" jit_log_name(vfile, layer, vrown, why) "(" why ")"
            sep = ", "
          }
          continue
        }
        vlk = jit_loc_key("vocabulary", layer, vfile)
        if (!(vlk in shown) && (index(padded, " " kw " ") > 0 || (stale != "" && index(stale, " " kw " ") > 0))) {
          if (vfile in vmatch) {
            if (index("|" vmatch[vfile] "|", "|" kw "|") == 0) vmatch[vfile] = vmatch[vfile] "|" kw
          } else { vmatch[vfile] = kw; vmrow[vfile] = vrown }
          if (kwverdict != "generic") vspecific[vfile] = 1
        }
      }
      close(lookup)
      for (vfile in vmatch) {
        generic_only = !(vfile in vspecific)
        vc = ""
        vpath = ENVIRON["JIT_BASE"] "/vocabulary/" layer "/" vfile
        if (jit_entry_load(vpath, inject_default, 0, vent)) {
          if (generic_only) vent["mode"] = "summary"
          vc = jit_inject_text(vent, ".claude/jit-context/vocabulary/" layer "/" vfile, vpath)
        } else if (vent["why"] != "") {
          why = vent["why"]
          n_refused++
          refused = jit_refuse_add(refused, jit_row_id("vocabulary/" layer, vmrow[vfile]) ": " why)
          log_matches = log_matches sep "refused:" jit_log_name(vfile, layer, vmrow[vfile], why) "(" why ")"
          sep = ", "
          continue
        }
        if (vc != "") {
          if (blocked != "") {
            withheld_log = withheld_log wsep layer ":" vfile "(" vmatch[vfile] ")" jit_inject_tag(vent)
            wsep = ", "
            continue
          }
          vlk = jit_loc_key("vocabulary", layer, vfile)
          if (!generic_only) {
            shown[vlk] = 1
            jit_shown_mark(shown_file, vlk)
          }
          vage = (layer ~ /00-manual/) ? jit_entry_age(layer "/" vfile) : ""
          vh = "# Vocabulary: " vfile " (matched: " vmatch[vfile] (vage != "" ? " · last edited " vage "d ago" : "") ")"
          if (layer ~ /00-manual/) vh = vh "\\n[vocab-upkeep] Learned something new here, or found this entry wrong? Edit it now — hand-written entries live in 00-manual/."
          log_matches = log_matches sep layer ":" vfile "(" vmatch[vfile] ")" jit_inject_tag(vent) (generic_only ? ":generic-only" : "")
          sep = ", "
          nblk++; blk[nblk] = vh "\n" vc
          if (!generic_only) jit_shown_mark(bytes_shown_file, vlk "\t" length(vh "\n" vc))
          if (status_mode == "fired") sys_msg = sys_msg (sys_msg != "" ? "\n" : "") "JIT : vocabulary/" layer "/" vfile " (" jit_fmt_bytes(length(vh "\n" vc)) ")"
        }
      }
    }
  }
  if (n_unreached > 0 && !("jit-no-subject" in shown)) {
    shown["jit-no-subject"] = 1
    jit_shown_mark(shown_file, "jit-no-subject")
    unote = jit_no_subject_notice(unreached, n_unreached)
    if (blocked == "") jit_blk_prepend(unote)
    else block_tail = block_tail "\n---\n" unote
  }
  if (n_refused > 0 && !("jit-refused-rules" in shown)) {
    note = jit_refusal_notice(refused, n_refused)
    if (blocked == "") {
      shown["jit-refused-rules"] = 1
      jit_shown_mark(shown_file, "jit-refused-rules")
      jit_blk_prepend(note)
    } else {
      block_tail = block_tail "\n---\n" note
    }
  }
  layers_refused = ENVIRON["JIT_LAYERS_REFUSED"]
  layers_refused_n = ENVIRON["JIT_LAYERS_REFUSED_N"] + 0
  if (layers_refused_n > 0 && !("jit-refused-layers" in shown)) {
    shown["jit-refused-layers"] = 1
    jit_shown_mark(shown_file, "jit-refused-layers")
    lnote = jit_layers_notice(layers_refused, layers_refused_n)
    if (blocked == "") jit_blk_prepend(lnote)
    else block_tail = block_tail "\n---\n" lnote
  }
  config_refused = ENVIRON["JIT_CONFIG_REFUSED"]
  config_refused_n = ENVIRON["JIT_CONFIG_REFUSED_N"] + 0
  if (config_refused_n > 0 && !("jit-refused-config" in shown)) {
    shown["jit-refused-config"] = 1
    jit_shown_mark(shown_file, "jit-refused-config")
    cnote = jit_config_notice(config_refused, config_refused_n)
    if (blocked == "") jit_blk_prepend(cnote)
    else block_tail = block_tail "\n---\n" cnote
  }
  worktree_note = ENVIRON["JIT_WORKTREE_NOTE"]
  if (worktree_note != "" && !("jit-worktree-mismatch" in shown)) {
    shown["jit-worktree-mismatch"] = 1
    jit_shown_mark(shown_file, "jit-worktree-mismatch")
    wnote = jit_worktree_notice(worktree_note)
    if (blocked == "") jit_blk_prepend(wnote)
    else block_tail = block_tail "\n---\n" wnote
  }
  sc = 0; for (s in shown) sc++
  tt_short = substr(jit_log_text(tt), 1, 120)
  tool_log = jit_log_text(tool_name)
  if (withheld_log != "") { log_matches = log_matches sep "withheld[" withheld_log "]"; sep = ", " }
  if (log_matches == "") log_matches = "(none)"
  if (log_tmp != "") {
    jit_shown_flush(log_tmp)
    printf "%s\t%s\t%d\t%s\n", tool_log, log_matches, sc, tt_short > log_tmp
    close(log_tmp)
  }
  if (blocked != "") {
    if (status_mode == "fired" && sys_msg_block_file != "") {
      sys_msg = "JIT : " sys_msg_block_file " (" jit_fmt_bytes(length(blocked block_tail)) ") — blocked"
    }
    blocked = jit_json_escape(blocked block_tail)
    printf "%s", jit_envelope_block_sysmsg(blocked, (sys_msg != "") ? jit_json_escape(sys_msg) : "")
  } else if ((matched = jit_blk_join()) != "") {
    matched = jit_json_escape(matched)
    printf "%s", jit_envelope_inject_sysmsg("PreToolUse", matched, (sys_msg != "") ? jit_json_escape(sys_msg) : "")
  } else {
    print "{}"
  }
}
'
JIT_AWK_PROGRAM_FILE=""
JIT_AWK_PROGRAM_TMPDIR="${TMPDIR:-/tmp}"
JIT_AWK_PROGRAM_TMPDIR="${JIT_AWK_PROGRAM_TMPDIR%/}"
JIT_AWK_PROGRAM_FILE="$(mktemp "$JIT_AWK_PROGRAM_TMPDIR/claude-jit-awk-XXXXXXXX" 2> /dev/null)" || JIT_AWK_PROGRAM_FILE=""
if [ -n "$JIT_AWK_PROGRAM_FILE" ]; then
  if printf '%s' "$JIT_AWK_PROGRAM" > "$JIT_AWK_PROGRAM_FILE" 2> /dev/null; then
    trap 'rm -f "$JIT_TMP" "$JIT_AWK_PROGRAM_FILE"' EXIT
  else
    rm -f "$JIT_AWK_PROGRAM_FILE"
    JIT_AWK_PROGRAM_FILE=""
  fi
fi
if [ -n "$JIT_AWK_PROGRAM_FILE" ]; then
  jit_awk_capture awk "${JIT_AWK_ARGS[@]}" -f "$JIT_AWK_PROGRAM_FILE"
else
  jit_awk_capture awk "${JIT_AWK_ARGS[@]}" -f <(printf '%s' "$JIT_AWK_PROGRAM")
fi
jit_awk_dispatch jit_awk_crash_block jit_awk_crash_block
T_END=$(_ms)
TOTAL=$((T_END - T_START))
if [ -n "$JIT_TMP" ] && [ -s "$JIT_TMP" ]; then
  {
    jit_marks_read
    IFS=$'\t' read -r AWK_TOOL AWK_MATCHES AWK_SHOWN AWK_TEXT
  } < "$JIT_TMP"
  jit_shown_apply
  _log_hook "pre-tool ($AWK_TOOL)" "$TOTAL" "$AWK_MATCHES" "[shown:$AWK_SHOWN] $JIT_LOG_ARROW $AWK_TEXT"
fi
exit 0
