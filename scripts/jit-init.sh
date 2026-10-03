#!/bin/bash
# jit-context — seed a project with the three dimensions and one starter entry.
#
# Why this exists: a fresh install matches nothing and injects nothing (#81). The hooks
# create only the .discovery machinery — no paths/, no tools/, no vocabulary/, and no
# entries — so the first-run experience is "install it, and nothing happens", and the one
# question a new user is guaranteed to ask is the one the plugin could answer with its own
# mechanism, at the moment they ask it.
#
# This copies ONE vocabulary entry into the project, explicitly, on request. The file is
# then the user's: theirs to edit, theirs to delete. Nothing is shipped into a repository
# unasked, and no hook reads a rule from outside the project directory.
#
# Usage:
#   bash scripts/jit-init.sh                     # seed ./.claude/jit-context
#   bash scripts/jit-init.sh --base DIR          # seed DIR, which must end in
#                                                #   /.claude/jit-context
#
# Exit: 0 seeded, and the index rebuilt so the entry is live | 1 refused — the entry is
#       already there and a copy you edited is not ours to replace, or the rebuild did
#       not complete and the entry is on disk and inert | 2 could not evaluate: a bad
#       argument, a --base that is not a <project>/.claude/jit-context path, a symbolic
#       link at or below .claude, an install with no template to copy, or a directory
#       that could not be created.
#
# --base is resolved before anything is written, so what it prints is the physical
# location of the files and not the spelling you handed it: a link above .claude is
# followed and reported, `..` is folded. A link at or below .claude is refused instead —
# the hooks will not read an entry through one, so seeding past it is a dead rule.
#
# This is tooling, not a hook. It is run deliberately, by a person, and it fails loudly —
# the opposite of scripts/*-hook.sh, which must never fail at all. See
# .claude/jit-context/paths/00-manual/tooling.md.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_ROOT="$SCRIPT_DIR/../templates/jit-context"
SEED_REL="vocabulary/00-manual/writing-rules.md"
BASE="$(pwd)/.claude/jit-context"
usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}
need_value() {
  echo "SKIPPED: $1 needs a value" >&2
  echo "         Run with --help for the accepted flags. Nothing was written." >&2
  exit 2
}
if [ "${1:-}" = "--arguments-string" ]; then
  [ $# -ge 2 ] || need_value "$1"
  IFS=' ' read -r -a _jit_init_split_args <<< "${2:-}"
  shift 2
  set -- "${_jit_init_split_args[@]+"${_jit_init_split_args[@]}"}" "$@"
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ $# -ge 2 ] || need_value "$1"
      BASE="$2"
      shift 2
      ;;
    -h | --help) usage 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage 2
      ;;
  esac
done
BASE="${BASE%/}"
case "$BASE" in
  /* | ?:/* | ?:\\*) ;;
  *) BASE="$(pwd)/$BASE" ;;
esac
case "$BASE" in
  */.claude/jit-context) PROJECT="${BASE%/.claude/jit-context}" ;;
  *)
    echo "SKIPPED: --base must end in /.claude/jit-context — the hooks resolve rules from" >&2
    echo "         <project>/.claude/jit-context and nowhere else, so seeding any other" >&2
    echo "         directory would write entries that can never fire. Got: $BASE" >&2
    exit 2
    ;;
esac
resolve_dir() {
  local head="$1" tail="" phys out c
  while [ ! -d "$head" ]; do
    case "$head" in */*) ;; *) break ;; esac # "C:" on Git Bash, or a bare word
    tail="${head##*/}${tail:+/}$tail"
    head="${head%/*}"
    [ -n "$head" ] || head="/"
  done
  if [ -d "$head" ]; then
    phys="$(CDPATH='' cd -P "$head" 2> /dev/null && pwd -P)"
    [ -n "$phys" ] && head="$phys"
  fi
  if [ -z "$tail" ]; then
    printf '%s\n' "$head"
    return 0
  fi
  out="${head%/}"
  local IFS=/
  set -f
  for c in $tail; do
    case "$c" in
      '' | .) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$c" ;;
    esac
  done
  set +f
  [ -n "$out" ] || out="/"
  printf '%s\n' "$out"
}
PROJECT="$(resolve_dir "$PROJECT")"
BASE="$PROJECT/.claude/jit-context"
SEED="$BASE/$SEED_REL"
TEMPLATE="$TEMPLATE_ROOT/$SEED_REL"
if [ ! -f "$TEMPLATE" ]; then
  echo "SKIPPED: no entry to seed — $TEMPLATE is missing." >&2
  echo "         That is an incomplete install, not an empty project. Nothing was written." >&2
  exit 2
fi
LINKED=""
for part in "$PROJECT/.claude" "$BASE"; do
  [ -L "$part" ] && LINKED="$part"
done
for dim in vocabulary paths tools; do
  [ -L "$BASE/$dim" ] && LINKED="$BASE/$dim"
  [ -L "$BASE/$dim/00-manual" ] && LINKED="$BASE/$dim/00-manual"
done
if [ -n "$LINKED" ]; then
  echo "SKIPPED: $LINKED is a symbolic link. Writing through it would put entries outside" >&2
  echo "         the tree you named. Nothing was written." >&2
  exit 2
fi
if [ -e "$SEED" ] || [ -L "$SEED" ]; then
  echo "REFUSED: $SEED_REL is already there." >&2
  echo "         $SEED" >&2
  echo "         A copy you edited is not ours to replace. Delete it first if you want the" >&2
  echo "         shipped text back, or leave it alone — it is your file now." >&2
  echo "         Nothing was created and nothing was changed by this run." >&2
  exit 1
fi
for dim in vocabulary paths tools; do
  if ! mkdir -p "$BASE/$dim/00-manual"; then
    echo "SKIPPED: could not create $BASE/$dim/00-manual — nothing was seeded." >&2
    exit 2
  fi
done
if ! cp "$TEMPLATE" "$SEED"; then
  echo "SKIPPED: could not write $SEED — nothing was seeded." >&2
  exit 2
fi
echo "seeded  $SEED"
REBUILD="$SCRIPT_DIR/rebuild-tsv.sh"
if [ ! -f "$REBUILD" ]; then
  echo "SKIPPED: $REBUILD is missing, so the index was not rebuilt and the entry just" >&2
  echo "         written cannot fire. Run rebuild-tsv.sh yourself." >&2
  exit 2
fi
CPD="${PROJECT:-/}"
__jit_run_rebuild_tsv_sh() (
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
jit_cfg_clean_line() {
  local LC_ALL=C
  local line="$1"
  line="${line%$'\r'}"
  while [ "$line" != "${line#[[:space:]]}" ]; do line="${line#[[:space:]]}"; done
  case "$line" in
    '' | '#'*) return 1 ;;
  esac
  local rest="${line#export}"
  if [ "$rest" != "$line" ] && [ "${rest#[[:space:]]}" != "$rest" ]; then
    line="$rest"
    while [ "$line" != "${line#[[:space:]]}" ]; do line="${line#[[:space:]]}"; done
  fi
  JIT_CFG_LINE="$line"
}
jit_config_name_ok() {
  local LC_ALL=C
  local prefix
  [ -n "$1" ] && [ -z "${1//[A-Za-z0-9_]/}" ] || return 1
  for prefix in JIT_CONTEXT_ DYNAMIC_RULES_ DVSI_; do
    if [ "${1#"$prefix"}" != "$1" ] && [ -n "${1#"$prefix"}" ]; then
      return 0
    fi
  done
  return 1
}
jit_cfg_split() {
  local LC_ALL=C
  JIT_CFG_REASON=""
  if [ "${1#*=}" = "$1" ]; then
    JIT_CFG_NAME=""
    JIT_CFG_VALUE=""
    JIT_CFG_REASON="not a KEY=VALUE assignment"
    return 1
  fi
  JIT_CFG_NAME="${1%%=*}"
  JIT_CFG_VALUE="${1#*=}"
  if ! jit_config_name_ok "$JIT_CFG_NAME"; then
    JIT_CFG_REASON="unknown setting (only JIT_CONTEXT_*, DYNAMIC_RULES_* and DVSI_* are read)"
    return 1
  fi
}
jit_cfg_unquote() {
  local LC_ALL=C
  local value="$1" reason="" q rest tail
  local dq sq
  printf -v dq '\042'
  printf -v sq '\047'
  q="${value%"${value#?}"}"
  if [ "$q" = "$dq" ] || [ "$q" = "$sq" ]; then
    rest="${value#?}"
    if [ "${rest#*"$q"}" != "$rest" ]; then
      tail="${rest#*"$q"}"
      while [ "$tail" != "${tail#[[:space:]]}" ]; do tail="${tail#[[:space:]]}"; done
      if [ -z "$tail" ] || [ "${tail#\#}" != "$tail" ]; then
        value="${rest%%"$q"*}"
      else
        reason="trailing text after the closing quote"
      fi
    else
      reason="unterminated quote"
    fi
  else
    value="${value%%[[:space:]]#*}"
    while [ "$value" != "${value%[[:space:]]}" ]; do value="${value%[[:space:]]}"; done
  fi
  JIT_CFG_VALUE="$value"
  JIT_CFG_REASON="$reason"
  [ -z "$reason" ]
}
jit_cfg_check_value() {
  local LC_ALL=C
  local cfg_name="$1" value="$2"
  JIT_CFG_REASON=""
  if [ "$cfg_name" = JIT_CONTEXT_INJECT ]; then
    if [ "$value" != summary ] && [ "$value" != full ]; then
      JIT_CFG_REASON="not an injection mode (the modes are summary and full)"
      return 1
    fi
  fi
  if [ "$cfg_name" = JIT_CONTEXT_STOP_REPORT ]; then
    if [ "$value" != 0 ] && [ "$value" != 1 ]; then
      JIT_CFG_REASON="not a stop-report toggle (0 or 1)"
      return 1
    fi
  fi
  if [ "$cfg_name" = JIT_CONTEXT_STATUS ]; then
    if [ "$value" != fired ] && [ "$value" != summary ] && [ "$value" != off ]; then
      JIT_CFG_REASON="not a status mode (fired, summary or off)"
      return 1
    fi
  fi
  if [ "$cfg_name" = JIT_CONTEXT_MISSES ]; then
    if [ "$value" != on ] && [ "$value" != off ]; then
      JIT_CFG_REASON="not a misses toggle (on or off)"
      return 1
    fi
  fi
  if [ "$cfg_name" = JIT_CONTEXT_LOG_MAX_BYTES ]; then
    if [ "$value" != 0 ]; then
      if [ "${value#[1-9]}" = "$value" ] || [ -n "${value//[0-9]/}" ]; then
        JIT_CFG_REASON="not a byte count (0, or digits with no leading zero)"
        return 1
      fi
    fi
  fi
  return 0
}
jit_cfg_assign() {
  if [ "$1" = DVSI_AUTONOMOUS_VOCAB_PATHS ]; then
    DVSI_AUTONOMOUS_VOCAB_PATHS="$2"
    return 0
  fi
  if [ "$1" = DYNAMIC_RULES_CHECKOUT_WINDOW_S ]; then
    DYNAMIC_RULES_CHECKOUT_WINDOW_S="$2"
    return 0
  fi
  if [ "$1" = DYNAMIC_RULES_COLLISION_BYTES ]; then
    DYNAMIC_RULES_COLLISION_BYTES="$2"
    return 0
  fi
  if [ "$1" = DYNAMIC_RULES_GENERIC_WORDS ]; then
    DYNAMIC_RULES_GENERIC_WORDS="$2"
    return 0
  fi
  if [ "$1" = DYNAMIC_RULES_KEYWORD_BLACKLIST ]; then
    DYNAMIC_RULES_KEYWORD_BLACKLIST="$2"
    return 0
  fi
  if [ "$1" = DYNAMIC_RULES_MODULE_PREFIX ]; then
    DYNAMIC_RULES_MODULE_PREFIX="$2"
    return 0
  fi
  if [ "$1" = DYNAMIC_RULES_VOCAB_PATHS ]; then
    DYNAMIC_RULES_VOCAB_PATHS="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_ALLOW_CROSS_TREE ]; then
    JIT_CONTEXT_ALLOW_CROSS_TREE="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_CHECKOUT_WINDOW_S ]; then
    JIT_CONTEXT_CHECKOUT_WINDOW_S="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_COLLISION_BYTES ]; then
    JIT_CONTEXT_COLLISION_BYTES="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_DOCTOR_MAX_BYTES ]; then
    JIT_CONTEXT_DOCTOR_MAX_BYTES="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_DOCTOR_MIN_KEYWORD ]; then
    JIT_CONTEXT_DOCTOR_MIN_KEYWORD="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_GENERIC_WORDS ]; then
    JIT_CONTEXT_GENERIC_WORDS="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_INJECT ]; then
    JIT_CONTEXT_INJECT="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_KEYWORD_BLACKLIST ]; then
    JIT_CONTEXT_KEYWORD_BLACKLIST="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_LOG_MAX_BYTES ]; then
    JIT_CONTEXT_LOG_MAX_BYTES="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_MISSES ]; then
    JIT_CONTEXT_MISSES="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_MODULE_PREFIX ]; then
    JIT_CONTEXT_MODULE_PREFIX="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_STATUS ]; then
    JIT_CONTEXT_STATUS="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_STOP_REPORT ]; then
    JIT_CONTEXT_STOP_REPORT="$2"
    return 0
  fi
  if [ "$1" = JIT_CONTEXT_VOCAB_PATHS ]; then
    JIT_CONTEXT_VOCAB_PATHS="$2"
    return 0
  fi
  return 0
}
jit_load_config() {
  local file="$1" line lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    jit_cfg_clean_line "$line" || continue
    if jit_cfg_split "$JIT_CFG_LINE" \
      && jit_cfg_unquote "$JIT_CFG_VALUE" \
      && jit_cfg_check_value "$JIT_CFG_NAME" "$JIT_CFG_VALUE"; then
      jit_cfg_assign "$JIT_CFG_NAME" "$JIT_CFG_VALUE"
    else
      jit_config_refuse "$lineno" "$JIT_CFG_REASON"
    fi
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
_log() {
  local line="$1 ${2}ms | $3"
  jit_log_write "[$(_ts)] $line"
  echo "$line"
}
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
    if (c == "\134") {
      nx = substr(p, i + 1, 1)
      if (nx == "") return "trailing backslash"
      if (nx ~ /[[:alnum:]]/ && nx !~ /^[ntr]$/) return "undefined escape \134" nx
      if (nx > "\177") return "undefined escape \\ before a non-ASCII byte"
      i++
      continue
    }
    if (inbr) {
      nx = substr(p, i + 1, 1)
      if (c == "[" && nx != "" && index(sprintf("%c%c%c", 58, 46, 61), nx) > 0) {
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
  if (index(f, "/") > 0 || index(f, "\134") > 0) return "not a bare file name"
  if (f == "\056" || f == "\056\056") return "not a bare file name"
  if (substr(f, 1, 1) == "\056") return "the entry file name begins with a dot, so rename it without one"
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
  if (s == "" || s == "\056" || s == "\056\056") return 0
  if (substr(s, 1, 1) == "\056") return 0
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
  while (c < n && substr(s, n - c, 1) == "\134") c++
  return c
}
function jit_json_fields(s, raw, fs, fe,   n, i, k) {
  n = split(s, raw, "\042")
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
  for (i = a + 1; i <= b; i++) o = o "\042" raw[i]
  return o
}
function jit_unescape(s,   n, i, c, nx, o) {
  if (index(s, "\134") == 0) return s
  n = length(s); o = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c != "\134" || i == n) { o = o c; continue }
    nx = substr(s, i + 1, 1)
    if (nx == "n") o = o "\n"
    else if (nx == "t") o = o "\t"
    else if (nx == "r") o = o "\r"
    else if (nx == "b") o = o "\b"
    else if (nx == "f") o = o "\f"
    else if (nx == "\042") o = o "\042"
    else if (nx == "/") o = o "/"
    else if (nx == "\134") o = o "\134"
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
  if (index(s, "\134") == 0) return s
  n = length(s); o = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c != "\134" || i == n) { o = o c; continue }
    nx = substr(s, i + 1, 1)
    if (nx == "n") { o = o "\n"; i++; continue }
    if (nx == "t") { o = o "\t"; i++; continue }
    if (nx == "r") { o = o "\r"; i++; continue }
    if (nx == "b") { o = o "\b"; i++; continue }
    if (nx == "f") { o = o "\f"; i++; continue }
    if (nx == "\042") { o = o "\042"; i++; continue }
    if (nx == "/") { o = o "/"; i++; continue }
    if (nx == "\134") { o = o "\134"; i++; continue }
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
jit_frontmatter() {
  local _out
  _out="$(LC_ALL=C awk -v fl="$1" "$JIT_AWK_FRONTMATTER" "$2")"
  [ -n "$_out" ] || return 0
  printf '%s\n' "${_out#*	}"
}
JIT_VALID_MODE_RE='^(remind|block|once)(,(remind|block|once))*$'
JIT_VALID_REQUIRES_RE='^[A-Za-z0-9._+-]{1,255}$'
JIT_MACRO_ANCHOR='(^|[;&|\n] *)'
JIT_MACRO_WRAP='(([a-z_][a-z0-9_]*=[^[:space:];&|]*|rtk|command|[e]nv|sudo|nohup|nice|time)[[:space:]]+)*'
JIT_MACRO_OPT='(-[^[:space:];&|]*[[:space:]]+([^-;&|[:space:]][^[:space:];&|]*[[:space:]]+)?)*'
JIT_MACRO_END='($|[[:space:];&|])'
jit_macro_word() {
  local w="$1" out="" i n c plain
  n=${#w}
  for ((i = 0; i < n; i++)); do
    c="${w:i:1}"
    plain=0
    case "$c" in [a-z0-9_/]) plain=1 ;; esac
    if [ "$plain" = 1 ]; then out="$out$c"; else out="${out}[$c]"; fi
  done
  printf '%s' "$out"
}
jit_expand_match() {
  local raw="$1" dim="${2:-tools}" label="${3:-<entry>}"
  local body name args reason="" out word first=1
  case "$raw" in '~'*) body="${raw#\~}" ;; *) body="$raw" ;; esac
  case "$body" in '@'*) ;; *)
    printf '%s' "$raw"
    return 0
    ;;
  esac
  name="${body#@}"
  args=""
  if [ "${name%%[[:space:]]*}" != "$name" ]; then
    args="${name#*[[:space:]]}"
    name="${name%%[[:space:]]*}"
  fi
  while [ "$args" != "${args#[[:space:]]}" ]; do args="${args#[[:space:]]}"; done
  while [ "$args" != "${args%[[:space:]]}" ]; do args="${args%[[:space:]]}"; done
  args="$(printf '%s' "$args" | tr '[:upper:]' '[:lower:]')"
  if [ "$dim" != "tools" ]; then
    reason="@$name describes a COMMAND, and a $dim rule is matched against a file path"
  elif [ "$name" != "invocation" ] && [ "$name" != "invocation-quoted-arg" ]; then
    reason="unknown macro @$name -- the macros are @invocation and @invocation-quoted-arg"
  elif [ -z "$args" ]; then
    reason="@$name needs the command it targets, e.g. 'match: ~@$name git push'"
  else
    case "$args" in
      *[!a-z0-9._/:+\ -]*) reason="@$name takes plain command words, and this one carries a character that is not one" ;;
    esac
  fi
  if [ -n "$reason" ]; then
    printf '%s' "$raw"
    printf 'REFUSED  %s: %s\n' "$label" "$reason" >&2
    printf '         written through unexpanded, so the hook refuses that row by name rather than matching nothing.\n' >&2
    return 1
  fi
  out="$JIT_MACRO_ANCHOR$JIT_MACRO_WRAP"
  for word in $args; do
    [ "$first" = 1 ] || out="${out}[[:space:]]+${JIT_MACRO_OPT}"
    out="$out$(jit_macro_word "$word")"
    first=0
  done
  case "$name" in
    invocation) out="$out$JIT_MACRO_END" ;;
    invocation-quoted-arg) out="${out}[[:space:]]+${JIT_MACRO_OPT}['\"]" ;;
  esac

  # The ~ is not optional and is not copied from the author: a tools row without it is a
  # substring rule, and a substring rule whose text is an ERE can never match anything.
  printf '~%s' "$out"
}

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
jit_generic_words_members() {
  local path="$1" f
  [ -n "$path" ] || return 0
  if [ -f "$path" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  if [ -d "$path" ]; then
    for f in "$path"/*.txt; do
      [ -f "$f" ] || continue
      printf '%s\n' "$f"
    done | LC_ALL=C sort
  fi
  return 0
}
LOG_FILE="$LOG_DIR/pipeline.log"
if [ -L "$LOG_FILE" ]; then JIT_LOG_DISABLED=1; fi
if [ "${CLAUDE_PROJECT_DIR+set}" = "set" ] && [ -z "$CLAUDE_PROJECT_DIR" ]; then
  echo "FATAL    refusing: CLAUDE_PROJECT_DIR is set but empty" >&2
  echo "         Something exported CLAUDE_PROJECT_DIR without giving it a value -- an" >&2
  echo "         interpolated variable that itself never resolved, most likely. JIT_BASE" >&2
  echo "         would otherwise fall through to the current directory's .claude/jit-context (common.sh)," >&2
  echo "         which is whatever tree this shell happens to be standing in (#417)." >&2
  echo "         Unset CLAUDE_PROJECT_DIR outright to use the current directory on purpose, or export" >&2
  echo "         it with a real value." >&2
  exit 2
fi
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ "${JIT_CONTEXT_ALLOW_CROSS_TREE:-}" != "1" ]; then
  JIT_CWD_TOP="$(git rev-parse --show-toplevel 2> /dev/null)"
  JIT_PROJ_TOP="$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2> /dev/null)"
  if [ -n "$JIT_CWD_TOP" ] && [ -n "$JIT_PROJ_TOP" ] && [ "$JIT_CWD_TOP" != "$JIT_PROJ_TOP" ]; then
    echo "FATAL    refusing: cwd's git tree is not CLAUDE_PROJECT_DIR's" >&2
    echo "         cwd's tree:            $JIT_CWD_TOP" >&2
    echo "         CLAUDE_PROJECT_DIR's:  $JIT_PROJ_TOP" >&2
    echo "         Rebuilding would write JIT_BASE=$JIT_BASE -- inside the SECOND tree, not" >&2
    echo "         the one this shell is standing in. That is #231's shape: an agent" >&2
    echo "         working a git worktree inherits a stale CLAUDE_PROJECT_DIR from the" >&2
    echo "         session that launched it and silently rewrites the other tree's index" >&2
    echo "         (it can just as well be an unrelated CLAUDE_PROJECT_DIR left over from" >&2
    echo "         a different project -- this check cannot tell the two apart, and" >&2
    echo "         refuses either way rather than guessing which one you meant)." >&2
    echo "         If CLAUDE_PROJECT_DIR is the tree you actually mean to rebuild, set" >&2
    echo "         JIT_CONTEXT_ALLOW_CROSS_TREE=1 and run this again." >&2
    exit 2
  fi
  if [ -z "$JIT_CWD_TOP" ] || [ -z "$JIT_PROJ_TOP" ]; then
    if [ -z "$JIT_CWD_TOP" ] && [ -z "$JIT_PROJ_TOP" ]; then
      JIT_SKIP_WHY="cwd is not inside a git tree, and CLAUDE_PROJECT_DIR does not resolve to one either"
    elif [ -z "$JIT_CWD_TOP" ]; then
      JIT_SKIP_WHY="cwd is not inside a git tree"
    else
      JIT_SKIP_WHY="CLAUDE_PROJECT_DIR does not resolve to a git tree"
    fi
    echo "note:    cross-tree check (#231) could not run -- $JIT_SKIP_WHY." >&2
    echo "         This run cannot tell whether it is about to write the tree this shell" >&2
    echo "         is standing in. Compare cwd= and CLAUDE_PROJECT_DIR= in the receipt" >&2
    echo "         line below by eye." >&2
    unset JIT_SKIP_WHY
  fi
  unset JIT_CWD_TOP JIT_PROJ_TOP
fi
JIT_RC=0
jit_rc() {
  [ "$1" -gt "$JIT_RC" ] && JIT_RC="$1"
  return 0
}
JIT_AWK_REPORT_NAME='
function jit_report_name(s) {
  if (s == "" || length(s) > 64) return ENVIRON["JIT_NAME_WITHHELD"]
  if (s ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) return s
  return ENVIRON["JIT_NAME_WITHHELD"]
}
'
JIT_AWK_REPORT_KEYWORD='
function jit_report_keyword(s,   w, n) {
  if (s == "" || length(s) > 40) return ENVIRON["JIT_KEYWORD_WITHHELD"]
  if (s !~ /^[a-z0-9][a-z0-9 -]*$/) return ENVIRON["JIT_KEYWORD_WITHHELD"]
  n = split(s, w, " ")
  if (n > 4) return ENVIRON["JIT_KEYWORD_WITHHELD"]
  return s
}
'
JIT_UNINDEXED=""
JIT_UNINDEXED_N=0
jit_unindexed() {
  JIT_UNINDEXED_N=$((JIT_UNINDEXED_N + 1))
  JIT_UNINDEXED="$JIT_UNINDEXED    [$1] $(jit_report_name "$2"): $3
"
}
JIT_DIMS_FOUND=0
for _jit_d in tools paths vocabulary; do
  [ -d "$JIT_BASE/$_jit_d" ] && JIT_DIMS_FOUND=1
done
unset _jit_d
if [ "$JIT_DIMS_FOUND" = 0 ]; then
  echo "FATAL    no entry tree at $JIT_BASE" >&2
  echo "         -- none of tools/, paths/ or vocabulary/ is there, so nothing was indexed." >&2
  echo "         JIT_BASE resolves against CLAUDE_PROJECT_DIR, never the working directory," >&2
  echo "         so a rebuild run from the wrong root indexes nothing and used to say so" >&2
  echo "         with an exit 0. Currently CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-<unset, so the current directory>}" >&2
  exit 2
fi
echo "rebuild-tsv: writing JIT_BASE=$JIT_BASE (CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-<unset, so the current directory>}, cwd=$(pwd))" >&2
truncate_index() {
  local tsv="$1" disp="${2:-$1}" why=""
  if [ -L "$tsv" ]; then
    echo "FATAL    $disp: could not be written -- that path is a SYMBOLIC LINK, not a file" >&2
    echo "         -- refusing to truncate or write through a symlinked index path" >&2
    echo "         -- that index was NOT rebuilt and is now stale." >&2
    echo "         -- under JIT_BASE=$JIT_BASE" >&2
    jit_rc 2
    return 1
  fi
  if : 2> /dev/null > "$tsv"; then return 0; fi
  [ -d "$tsv" ] && why=" -- there is a DIRECTORY at that path, not a file"
  echo "FATAL    $disp: could not be written$why" >&2
  echo "         -- that index was NOT rebuilt and is now stale." >&2
  echo "         -- under JIT_BASE=$JIT_BASE" >&2
  jit_rc 2
  return 1
}
jit_layer_symlinked() {
  if [ -L "$1" ]; then
    echo "FATAL    $2: refusing a SYMBOLIC LINK layer directory -- not indexed (#332)" >&2
    jit_rc 2
    return 0
  fi
  return 1
}
jit_tsv_field() {
  local v="$1"
  v="${v//$'\t'/ }"
  v="${v//$'\r'/ }"
  v="${v//$'\n'/ }"
  printf '%s' "$v"
}
build_tool_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)
  [ -d "$dir" ] || return
  truncate_index "$tsv" "$label/${tsv##*/}" || return
  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue
    filename=$(jit_tsv_field "$filename")
    local tool match mode require forbid requires
    tool=$(jit_tsv_field "$(jit_frontmatter tool "$md")")
    match=$(jit_tsv_field "$(jit_frontmatter match "$md")")
    mode=$(jit_tsv_field "$(jit_frontmatter mode "$md")")
    require=$(jit_tsv_field "$(jit_frontmatter require "$md")")
    forbid=$(jit_tsv_field "$(jit_frontmatter forbid "$md")")
    requires=$(jit_frontmatter requires "$md")
    requires="${requires//$'\t'/ }"
    requires="${requires//$'\n'/ }"
    if [ -n "$mode" ] && ! printf '%s' "$mode" | LC_ALL=C grep -Eq "$JIT_VALID_MODE_RE"; then
      jit_unindexed "$label" "$filename" "mode: \"$(jit_report_keyword "$mode")\" is not one of remind/block/once -- entry skipped rather than indexed with an unverified mode"
      jit_rc 1
      continue
    fi
    if [ -n "$requires" ] && ! printf '%s' "$requires" | LC_ALL=C grep -Eq "$JIT_VALID_REQUIRES_RE"; then
      jit_unindexed "$label" "$filename" "requires: \"$(jit_report_keyword "$requires")\" is not a bare binary name -- entry skipped rather than indexed with an unverified requires:"
      jit_rc 1
      continue
    fi
    if [ -z "$tool" ] || [ -z "$match" ]; then
      if [ -z "$tool" ] && [ -z "$match" ]; then
        jit_unindexed "$label" "$filename" "no tool: and no match: in its frontmatter"
      elif [ -z "$tool" ]; then
        jit_unindexed "$label" "$filename" "no tool: in its frontmatter"
      else
        jit_unindexed "$label" "$filename" "no match: in its frontmatter"
      fi
      continue
    fi
    match=$(jit_expand_match "$match" tools "$label/$(jit_report_name "$filename")") || jit_rc 1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tool" "$match" "$filename" "${mode:-remind}" "$require" "$forbid" "$requires" >> "$tsv"
  done
  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT rules"
}
TOOLS_BASE="$JIT_BASE/tools"
if [ -L "$TOOLS_BASE" ]; then
  echo "FATAL    tools: refusing a SYMBOLIC LINK dimension directory -- not indexed (#332)" >&2
  jit_rc 2
  TOOLS_BASE="$JIT_BASE/.jit-refused-symlinked-dimension-tools"
fi
for dir in "$TOOLS_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="tools/$(jit_report_name "$(basename "$dir")")"
  jit_layer_symlinked "$dir" "$label" && continue
  build_tool_tsv "$dir" "$dir/00-index.tsv" "$label"
done
VOCAB_KEYWORD_BLACKLIST="${JIT_CONTEXT_KEYWORD_BLACKLIST:-${DYNAMIC_RULES_KEYWORD_BLACKLIST:-^(extension|detection|count|output|input|name|branch|issue|documents|files|file)$}}"
VOCAB_KEYWORD_BLACKLIST_OK=1
if ! VOCAB_KEYWORD_BLACKLIST="$VOCAB_KEYWORD_BLACKLIST" LC_ALL=C awk \
  'BEGIN { if ("canary" ~ ENVIRON["VOCAB_KEYWORD_BLACKLIST"]) { } }' 2> /dev/null; then
  echo "FATAL    vocabulary: VOCAB_KEYWORD_BLACKLIST is not a valid extended regular expression -- treating it as matching NOTHING for this whole run (the same safe degrade a malformed pattern already produced per-keyword before #379). Fix JIT_CONTEXT_KEYWORD_BLACKLIST / DYNAMIC_RULES_KEYWORD_BLACKLIST in config.env." >&2
  jit_rc 2
  VOCAB_KEYWORD_BLACKLIST_OK=0
fi
GENERIC_WORDS_EXPLICIT=0
if [ "${JIT_CONTEXT_GENERIC_WORDS+set}" = "set" ]; then
  GENERIC_WORDS_FILE="$JIT_CONTEXT_GENERIC_WORDS"
  GENERIC_WORDS_EXPLICIT=1
elif [ "${DYNAMIC_RULES_GENERIC_WORDS+set}" = "set" ]; then
  GENERIC_WORDS_FILE="$DYNAMIC_RULES_GENERIC_WORDS"
  GENERIC_WORDS_EXPLICIT=1
else
  GENERIC_WORDS_FILE="$(dirname "$0")/../data/generic-words"
fi
GENERIC_WORDS_OK=0
GENERIC_WORDS_FILE_SAFE=$(printf '%s' "$GENERIC_WORDS_FILE" | LC_ALL=C tr -d '\000-\037\177')
if [ -z "$GENERIC_WORDS_FILE" ]; then
  : # opted out -- not an error
elif [ ! -e "$GENERIC_WORDS_FILE" ] && [ "$GENERIC_WORDS_EXPLICIT" -eq 0 ]; then
  : # nothing configured/shipped -- the documented degrade, not an error
elif [ ! -e "$GENERIC_WORDS_FILE" ]; then
  echo "FATAL    generic-word classifier: $GENERIC_WORDS_FILE_SAFE was explicitly configured (JIT_CONTEXT_GENERIC_WORDS or DYNAMIC_RULES_GENERIC_WORDS) but does not exist -- every keyword this run will read as non-generic (the pre-#232 degrade), which would otherwise be silent. Fix the path or unset the variable to accept the degrade on purpose." >&2
  jit_rc 2
elif [ ! -r "$GENERIC_WORDS_FILE" ]; then
  echo "FATAL    generic-word classifier: $GENERIC_WORDS_FILE_SAFE exists but is not readable -- every keyword this run will read as non-generic (the pre-#232 degrade), which would otherwise be silent. Fix its permissions or unset JIT_CONTEXT_GENERIC_WORDS to accept the degrade on purpose." >&2
  jit_rc 2
else
  GENERIC_WORDS_MEMBERS="$(jit_generic_words_members "$GENERIC_WORDS_FILE")"
  GENERIC_WORDS_LINES=0
  GENERIC_WORDS_UNREADABLE=""
  if [ -n "$GENERIC_WORDS_MEMBERS" ]; then
    while IFS= read -r _gw_member; do
      [ -n "$_gw_member" ] || continue
      if [ ! -r "$_gw_member" ]; then
        GENERIC_WORDS_UNREADABLE="${GENERIC_WORDS_UNREADABLE}${GENERIC_WORDS_UNREADABLE:+, }$_gw_member"
        continue
      fi
      _gw_n=$(LC_ALL=C awk 'END{print NR+0}' "$_gw_member" 2> /dev/null)
      case "$_gw_n" in "" | *[!0-9]*) _gw_n=0 ;; esac
      GENERIC_WORDS_LINES=$((GENERIC_WORDS_LINES + _gw_n))
    done <<< "$GENERIC_WORDS_MEMBERS"
  fi
  if [ -n "$GENERIC_WORDS_UNREADABLE" ]; then
    echo "FATAL    generic-word classifier: $GENERIC_WORDS_FILE_SAFE names a directory holding an unreadable member ($GENERIC_WORDS_UNREADABLE) -- every keyword this run will read as non-generic (the pre-#232 degrade), which would otherwise be silent. Fix its permissions or unset JIT_CONTEXT_GENERIC_WORDS to accept the degrade on purpose." >&2
    jit_rc 2
  elif [ "$GENERIC_WORDS_LINES" -eq 0 ]; then
    echo "FATAL    generic-word classifier: $GENERIC_WORDS_FILE_SAFE exists and is readable but is empty -- every keyword this run will read as non-generic (the pre-#232 degrade), which would otherwise be silent." >&2
    jit_rc 2
  else
    GENERIC_WORDS_OK=1
    GENERIC_WORDS_FILES="$GENERIC_WORDS_MEMBERS"
  fi
fi
MODULE_PREFIX="${JIT_CONTEXT_MODULE_PREFIX:-${DYNAMIC_RULES_MODULE_PREFIX:-src/}}"
JIT_DROPPED=""
JIT_IDCOLLISION=""
JIT_IDCOLLISION_N=0
JIT_ALLGENERIC=""
JIT_ALLGENERIC_N=0
build_vocab_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)
  if [ ! -d "$dir" ]; then
    return
  fi
  truncate_index "$tsv" "$label/${tsv##*/}" || return
  local ALL_KW=()
  local ENTRY_FILENAME=() ENTRY_START=() ENTRY_COUNT=()
  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue
    filename=$(jit_tsv_field "$filename")
    local kw_line kw_rc
    kw_line=$(LC_ALL=C awk '/^---$/{n++; next} n==1 && /^keywords:/{sub(/^keywords: */, ""); print; exit}' "$md")
    kw_rc=$?
    if [ "$kw_rc" -ne 0 ]; then
      jit_unindexed "$label" "$filename" "the frontmatter could not be read (awk exited $kw_rc) -- treated as unindexed rather than silently skipped"
      jit_rc 2
      continue
    fi
    if [ -z "$kw_line" ]; then
      jit_unindexed "$label" "$filename" "no keywords: in its frontmatter"
      continue
    fi
    kw_line=$(printf '%s\n' "$kw_line" | LC_ALL=C awk "$JIT_AWK_FOLD"'{ print jit_fold_latin1($0) }')
    local kw_written=0 kw_black=0 kw_empty=0
    local kw_rows=()
    local _kw_status _kw_val _kw_idflag _kw_rawdisp
    while IFS=$'\t' read -r _kw_status _kw_val _kw_idflag _kw_rawdisp; do
      case "$_kw_status" in
        E)
          kw_empty=$((kw_empty + 1))
          ;;
        B)
          JIT_DROPPED="$JIT_DROPPED    [$label] $(jit_report_name "$filename"): \"$(jit_report_keyword "$_kw_val")\"
"
          kw_black=$((kw_black + 1))
          ;;
        O)
          if [ "$_kw_idflag" = "1" ]; then
            JIT_IDCOLLISION="$JIT_IDCOLLISION    [$label] $(jit_report_name "$filename"): \"$_kw_rawdisp\" normalises to the ordinary-looking word \"$(jit_report_keyword "$_kw_val")\"
"
            JIT_IDCOLLISION_N=$((JIT_IDCOLLISION_N + 1))
          fi
          kw_rows+=("$_kw_val")
          kw_written=$((kw_written + 1))
          ;;
      esac
    done < <(printf '%s\n' "$kw_line" \
      | VOCAB_KEYWORD_BLACKLIST="$VOCAB_KEYWORD_BLACKLIST" \
        VOCAB_KEYWORD_BLACKLIST_OK="$VOCAB_KEYWORD_BLACKLIST_OK" LC_ALL=C awk '
        {
          n = split($0, segs, ",")
          for (i = 1; i <= n; i++) {
            raw = segs[i]
            gsub(/^[[:space:]]+/, "", raw)
            gsub(/[[:space:]]+$/, "", raw)
            # Normalize IDENTICALLY to the matcher (pre-prompt-hook.sh): lowercase, then
            # map any char outside [a-z0-9 -] to a space, collapse, trim. A keyword
            # authored with dots/slashes ("ops.deploy", "security/dast") would
            # otherwise be DEAD -- the matcher strips those from the prompt, so a dotted
            # keyword can never match.
            kw = tolower(segs[i])
            gsub(/[^a-z0-9 -]/, " ", kw)
            gsub(/ +/, " ", kw)
            gsub(/^ +/, "", kw)
            gsub(/ +$/, "", kw)
            if (kw == "") { print "E\t\t\t"; continue }
            # ENVIRON["VOCAB_KEYWORD_BLACKLIST_OK"] gates this: the caller validated
            # the pattern once, up front (see the VOCAB_KEYWORD_BLACKLIST_OK block
            # above build_vocab_tsv), specifically so a malformed pattern is never
            # actually EVALUATED here -- evaluating a bad ERE aborts the whole awk
            # process, not just this one keyword, which would drop every remaining
            # keyword of this file with no trace (#379 review finding). "0" reads as
            # "not blacklisted", the same safe degrade a bad pattern already produced
            # under the old per-keyword `grep -Eq`.
            if (ENVIRON["VOCAB_KEYWORD_BLACKLIST_OK"] == "1" && kw ~ ENVIRON["VOCAB_KEYWORD_BLACKLIST"]) { print "B\t" kw "\t\t"; continue }
            # A raw token with an internal capital -- not just a leading one, which is
            # ordinary title-casing -- reads as deliberately cased: an author writing
            # `jsOn` meant the identifier, not the sentence-initial word "json" is not.
            # Flagged only when normalising did NOTHING but fold that case away (no
            # digit/punctuation was stripped, no multi-word split happened) and the
            # collapsed spelling is short enough that it plausibly reads as an ordinary
            # word to a later author (#232). `[a-z0-9]+`, not `[a-z0-9]*`: a `*` would
            # let a raw token of nothing but capitals (`API`, `HTML`, `URL`) through,
            # since zero lowercase/digit characters between the leading letter and the
            # next capital is a valid empty match -- an all-caps acronym is not an
            # accidentally-cased identifier.
            idflag = 0
            rawdisp = ""
            if (raw ~ /^[A-Za-z][a-z0-9]+[A-Z][A-Za-z0-9]*$/) {
              rawlc = tolower(raw)
              if (rawlc == kw && length(kw) <= 6) {
                idflag = 1
                # $raw just matched the ERE above, which admits nothing but
                # [A-Za-z0-9], so there is no character left to withhold it for -- only
                # its LENGTH still needs a bound, since the regex has no upper one.
                rawdisp = (length(raw) <= 40) ? raw : ENVIRON["JIT_KEYWORD_WITHHELD"]
              }
            }
            print "O\t" kw "\t" idflag "\t" rawdisp
          }
        }
      ')
    local kw_line_nocommas="${kw_line//,/}"
    local kw_tok_count=$((${#kw_line} - ${#kw_line_nocommas} + 1))
    local kw_seen_count=$((kw_written + kw_black + kw_empty))
    local kw_classify_broken=0
    if [ "$kw_seen_count" -ne "$kw_tok_count" ]; then
      echo "FATAL    $label/${tsv##*/}: $(jit_report_name "$filename") -- the keyword classify pass returned $kw_seen_count verdict(s) for $kw_tok_count comma-separated term(s) in its keywords: line -- it did not finish (a crashed or truncated awk process), and every keyword past what it did return was silently dropped rather than classified." >&2
      jit_rc 2
      kw_classify_broken=1
    fi
    if [ "$kw_written" -gt 0 ]; then
      local _entry_i=${#ENTRY_FILENAME[@]}
      ENTRY_FILENAME[_entry_i]="$filename"
      ENTRY_START[_entry_i]=${#ALL_KW[@]}
      ENTRY_COUNT[_entry_i]=$kw_written
      ALL_KW+=("${kw_rows[@]}")
    fi
    if [ "$kw_classify_broken" -eq 0 ] && [ "$kw_written" -eq 0 ]; then
      if [ "$kw_black" -gt 0 ] && [ "$kw_empty" -gt 0 ]; then
        jit_unindexed "$label" "$filename" \
          "every keywords: term was dropped by the blacklist or normalised to nothing"
      elif [ "$kw_black" -gt 0 ]; then
        jit_unindexed "$label" "$filename" \
          "every keywords: term was dropped by the blacklist, so no row was written"
      else
        jit_unindexed "$label" "$filename" \
          "every keywords: term normalised to nothing -- the normaliser maps every byte outside [a-z0-9 -] to a space"
      fi
    fi
  done
  local VERDICT_FLAGS=()
  if [ "${#ALL_KW[@]}" -gt 0 ] && [ "$GENERIC_WORDS_OK" -eq 1 ]; then
    while IFS= read -r _vflag; do
      VERDICT_FLAGS+=("$_vflag")
    done < <(printf '%s\n' "${ALL_KW[@]}" | GENERIC_WORDS_FILES="$GENERIC_WORDS_FILES" LC_ALL=C awk '
      # #437: GENERIC_WORDS_FILE can now be several chunk files rather than one -- the
      # list travels through ENVIRON (never -v: a -v value has its escapes PROCESSED,
      # the same reason JIT_SYMLINKS above does not use -v either), newline-separated,
      # from jit_generic_words_members() in common.sh. Reading every member into the
      # SAME seen[] hash is what keeps this byte-identical to the single-file read it
      # replaces: a keyword classifies generic iff it is a line in ANY member, exactly
      # as it was a line of the one file before the split.
      BEGIN {
        n = split(ENVIRON["GENERIC_WORDS_FILES"], wfiles, "\n")
        for (i = 1; i <= n; i++) {
          wf = wfiles[i]
          if (wf == "") continue
          while ((getline w < wf) > 0) seen[w] = 1
          close(wf)
        }
      }
      { print ($0 in seen) ? 1 : 0 }
    ')
    if [ "${#VERDICT_FLAGS[@]}" -ne "${#ALL_KW[@]}" ]; then
      echo "FATAL    $label/${tsv##*/}: the generic-word classifier returned ${#VERDICT_FLAGS[@]} verdict(s) for ${#ALL_KW[@]} keyword(s) -- the classify pass did not finish, so every keyword past what it did return defaulted to non-generic and this run's third column is not one to trust." >&2
      jit_rc 2
    fi
  fi
  local _ei _entries_n=${#ENTRY_FILENAME[@]}
  for ((_ei = 0; _ei < _entries_n; _ei++)); do
    local _efile="${ENTRY_FILENAME[$_ei]}" _estart="${ENTRY_START[$_ei]}" _ecount="${ENTRY_COUNT[$_ei]}"
    local _entry_rows=() _kw_generic=0 _j _ekw _everdict
    for ((_j = _estart; _j < _estart + _ecount; _j++)); do
      _ekw="${ALL_KW[$_j]}"
      if [ "${VERDICT_FLAGS[_j]:-0}" = "1" ]; then
        _everdict="generic"
        _kw_generic=$((_kw_generic + 1))
      else
        _everdict=""
      fi
      _entry_rows+=("$(printf '%s\t%s\t%s' "$_ekw" "$_efile" "$_everdict")")
    done
    if [ "$_kw_generic" -eq "$_ecount" ]; then
      _entry_rows=()
      for ((_j = _estart; _j < _estart + _ecount; _j++)); do
        _entry_rows+=("$(printf '%s\t%s\t' "${ALL_KW[$_j]}" "$_efile")")
      done
      JIT_ALLGENERIC="$JIT_ALLGENERIC    [$label] $(jit_report_name "$_efile")
"
      JIT_ALLGENERIC_N=$((JIT_ALLGENERIC_N + 1))
    fi
    printf '%s\n' "${_entry_rows[@]}" >> "$tsv"
  done
  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT keywords"
}
VOCAB_BASE="$JIT_BASE/vocabulary"
if [ -L "$VOCAB_BASE" ]; then
  echo "FATAL    vocabulary: refusing a SYMBOLIC LINK dimension directory -- not indexed (#332)" >&2
  jit_rc 2
  VOCAB_BASE="$JIT_BASE/.jit-refused-symlinked-dimension-vocabulary"
fi
for dir in "$VOCAB_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="vocabulary/$(jit_report_name "$(basename "$dir")")"
  jit_layer_symlinked "$dir" "$label" && continue
  build_vocab_tsv "$dir" "$dir/00-index.tsv" "$label"
done
build_vocab_path_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)
  [ -d "$dir" ] || return
  truncate_index "$tsv" "$label/${tsv##*/}" || return
  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename mod_rc
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue
    filename=$(jit_tsv_field "$filename")
    LC_ALL=C awk -v file="$filename" -v prefix="$MODULE_PREFIX" '
      /^## Modules[[:space:]]*$/ { inmod = 1; next }
      inmod && /^#/ { inmod = 0 }
      inmod {
        gsub(/[^A-Za-z0-9]+/, " ")
        n = split($0, m, " ")
        for (i = 1; i <= n; i++) {
          if (m[i] == "") continue
          # Module names are PascalCase and non-trivial; skip prose fragments.
          if (m[i] !~ /^[A-Z][A-Za-z0-9]{2,}$/) continue
          if (seen[m[i]]) continue
          seen[m[i]] = 1
          printf "%s%s/\t%s\n", prefix, m[i], file
        }
      }
    ' "$md" >> "$tsv"
    mod_rc=$?
    if [ "$mod_rc" -ne 0 ]; then
      echo "FATAL    $label/${tsv##*/}: $(jit_report_name "$filename"): awk exited $mod_rc while reading its \"## Modules\" section -- rows for this file may be missing or partial, and the index is not this run" >&2
      jit_rc 2
    fi
  done
  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label/${tsv##*/}: $COUNT path mappings"
}
for dir in "$VOCAB_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="vocabulary/$(jit_report_name "$(basename "$dir")")"
  jit_layer_symlinked "$dir" "$label" && continue
  build_vocab_path_tsv "$dir" "$dir/01-paths.tsv" "$label"
done
build_path_tsv() {
  local dir="$1"
  local tsv="$2"
  local label="$3"
  local T0
  T0=$(_ms)
  [ -d "$dir" ] || return
  truncate_index "$tsv" "$label/${tsv##*/}" || return
  for md in "$dir"/*.md; do
    [ -f "$md" ] || continue
    local filename
    filename=$(basename "$md")
    [ "$filename" = "00-README.md" ] && continue
    filename=$(jit_tsv_field "$filename")
    local match_line
    match_line=$(jit_tsv_field "$(jit_frontmatter match "$md")")
    if [ -z "$match_line" ]; then
      jit_unindexed "$label" "$filename" "no match: in its frontmatter"
      continue
    fi
    match_line=$(jit_expand_match "$match_line" paths "$label/$(jit_report_name "$filename")") || jit_rc 1
    printf '%s\t%s\n' "$match_line" "$filename" >> "$tsv"
  done
  COUNT=$(wc -l < "$tsv" | tr -d ' ')
  _log "rebuild-tsv" $(($(_ms) - T0)) "$label: $COUNT rules"
}
PATHS_BASE="$JIT_BASE/paths"
if [ -L "$PATHS_BASE" ]; then
  echo "FATAL    paths: refusing a SYMBOLIC LINK dimension directory -- not indexed (#332)" >&2
  jit_rc 2
  PATHS_BASE="$JIT_BASE/.jit-refused-symlinked-dimension-paths"
fi
for dir in "$PATHS_BASE"/*/; do
  [ -d "$dir" ] || continue
  dir="${dir%/}"
  label="paths/$(jit_report_name "$(basename "$dir")")"
  jit_layer_symlinked "$dir" "$label" && continue
  build_path_tsv "$dir" "$dir/00-index.tsv" "$label"
done
report_bad_bytes() {
  local tsv="$1" label="$2" col="$3"
  [ -f "$tsv" ] || return 0
  LC_ALL=C JIT_COL="$col" awk "$JIT_AWK_ENTRY$JIT_AWK_REPORT_NAME"'
    BEGIN { col = ENVIRON["JIT_COL"] + 0 }
    {
      why = jit_bad_bytes($0, "the index row")
      if (why == "") next
      n = split($0, f, "\t")
      printf "rebuild-tsv: %s row %d: %s -- the hooks will refuse this row%s\n", \
        lbl, NR, why, (f[col] != "" && why ~ /UTF-8/ ? ", written from " jit_report_name(f[col]) : "")
    }' lbl="$label" "$tsv" >&2
}
for dir in "$TOOLS_BASE"/*/; do
  [ -d "$dir" ] || continue
  [ -L "${dir%/}" ] && continue
  report_bad_bytes "${dir%/}/00-index.tsv" "tools/$(jit_report_name "$(basename "${dir%/}")")" 3
done
for dir in "$PATHS_BASE"/*/; do
  [ -d "$dir" ] || continue
  [ -L "${dir%/}" ] && continue
  report_bad_bytes "${dir%/}/00-index.tsv" "paths/$(jit_report_name "$(basename "${dir%/}")")" 2
done
for dir in "$VOCAB_BASE"/*/; do
  [ -d "$dir" ] || continue
  [ -L "${dir%/}" ] && continue
  _jit_vlabel="vocabulary/$(jit_report_name "$(basename "${dir%/}")")"
  report_bad_bytes "${dir%/}/00-index.tsv" "$_jit_vlabel/00-index.tsv" 2
  report_bad_bytes "${dir%/}/01-paths.tsv" "$_jit_vlabel/01-paths.tsv" 2
done
unset _jit_vlabel
COLLISION_BYTES_FLOOR="${JIT_CONTEXT_COLLISION_BYTES:-${DYNAMIC_RULES_COLLISION_BYTES:-4096}}"
echo "" >&2
echo "=== Ambiguous vocabulary keywords (>${COLLISION_BYTES_FLOOR}b pulled in one match, every layer) ===" >&2
echo "Each match loads ALL listed files into context, across every layer the keyword appears in." >&2
echo "Prune \`keywords:\` frontmatter where the term isn't central, or merge entries that share it." >&2
echo "" >&2
out=$(
  for tsv in "$VOCAB_BASE"/*/00-index.tsv; do
    [ -f "$tsv" ] || continue
    layerdir="$(dirname "$tsv")"
    [ -L "$layerdir" ] && continue
    layer="vocabulary/$(jit_report_name "$(basename "$layerdir")")"
    LC_ALL=C awk -F'\t' -v layerdir="$layerdir" -v layer="$layer" "$JIT_AWK_REPORT_NAME"'
      function bytesof(path,    b, line, rc, first) {
        if (path in bcache) return bcache[path]
        b = 0; first = 1
        while ((rc = (getline line < path)) > 0) { b += length(line) + 1; first = 0 }
        close(path)
        if (rc < 0 && first) { bcache[path] = -1; return -1 }
        bcache[path] = b
        return b
      }
      $1 != "" && $2 != "" {
        printf "%s\t%d\t%s[%s]\n", $1, bytesof(layerdir "/" $2), jit_report_name($2), layer
      }
    ' "$tsv"
  done | LC_ALL=C awk -F'\t' -v floor="$COLLISION_BYTES_FLOOR" "$JIT_AWK_REPORT_KEYWORD"'
    function isort(v, kw, cn, fl, n,   i, j, tv, tk, tc, tf) {
      for (i = 2; i <= n; i++) {
        tv = v[i]; tk = kw[i]; tc = cn[i]; tf = fl[i]; j = i - 1
        while (j >= 1 && v[j] < tv) {
          v[j+1] = v[j]; kw[j+1] = kw[j]; cn[j+1] = cn[j]; fl[j+1] = fl[j]; j--
        }
        v[j+1] = tv; kw[j+1] = tk; cn[j+1] = tc; fl[j+1] = tf
      }
    }
    {
      if (!($1 in cnt)) { n++; ord[n] = $1 }
      cnt[$1]++
      if ($2 == -1) { miss[$1]++ } else { bytes[$1] += $2 }
      files[$1] = (files[$1] == "" ? $3 : files[$1] "," $3)
    }
    END {
      m = 0
      for (i = 1; i <= n; i++) {
        k = ord[i]
        if (cnt[k] >= 2 && (bytes[k] > floor || (k in miss))) {
          m++; bv[m] = bytes[k]; bk[m] = k; bc[m] = cnt[k]; bf[m] = files[k]
        }
      }
      if (m == 0) exit
      isort(bv, bk, bc, bf, m)
      for (i = 1; i <= m; i++) {
        note = (bk[i] in miss) ? sprintf(" -- %d file(s) could not be measured, total is a MINIMUM", miss[bk[i]]) : ""
        printf "%8d\t%4d entr(ies)\t\"%s\"%s\n\t  files: %s\n", bv[i], bc[i], jit_report_keyword(bk[i]), note, bf[i]
      }
    }
  '
)
if [ -n "$out" ]; then
  echo "$out" >&2
else
  echo "(none — no keyword pulls more than ${COLLISION_BYTES_FLOOR}b in one match)" >&2
fi
echo "" >&2
echo "=== Keywords dropped by the blacklist (listed, not indexed) ===" >&2
echo "These stay in \`keywords:\` frontmatter for human searching and are skipped at index time," >&2
echo "so the entry never fires on them. Widen or narrow with JIT_CONTEXT_KEYWORD_BLACKLIST." >&2
echo "" >&2
if [ -n "$JIT_DROPPED" ]; then
  printf '%s' "$JIT_DROPPED" >&2
else
  echo "(none — every keyword in every entry was indexed)" >&2
fi
echo "" >&2
echo "=== Keywords that read as an identifier before normalisation, and an ordinary word after it (#232) ===" >&2
echo "Normalisation lowercases and strips punctuation for matching. A term authored with" >&2
echo "internal capitals (jsOn) can collapse onto a completely different, unintended word" >&2
echo "(json) with nobody having chosen it. Rename the keyword, or accept the collision." >&2
echo "" >&2
if [ -n "$JIT_IDCOLLISION" ]; then
  printf '%s' "$JIT_IDCOLLISION" >&2
  echo "" >&2
  echo "$JIT_IDCOLLISION_N keyword(s) -- see the comment above the check in this script for what it does and does not catch." >&2
else
  echo "(none — no keyword's normalised spelling silently dropped its casing)" >&2
fi
echo "" >&2
echo "=== Entries whose keywords are ALL generic (fallback applied -- full body every match) ===" >&2
echo "Every keyword on these entries classified as an ordinary word, so the generic-only" >&2
echo "downgrade was cleared: they behave as before #232 -- full body, one shot spent, on" >&2
echo "any match. Add a specific keyword to any of these to get the downgrade's benefit." >&2
echo "" >&2
if [ -n "$JIT_ALLGENERIC" ]; then
  printf '%s' "$JIT_ALLGENERIC" >&2
  echo "" >&2
  echo "$JIT_ALLGENERIC_N entry/entries -- see the comment above the check in this script for why this degrades safely." >&2
else
  echo "(none — every entry on the tree owns at least one specific keyword)" >&2
fi
echo "" >&2
echo "=== Entries on disk with no row in the index (they can never fire) ===" >&2
echo "The hooks read 00-index.tsv, never your markdown. An entry with no row is on disk and" >&2
echo "can never fire -- which reads exactly like a rule that fires and never matches." >&2
echo "" >&2
if [ -n "$JIT_UNINDEXED" ]; then
  printf '%s' "$JIT_UNINDEXED" >&2
  echo "" >&2
  echo "$JIT_UNINDEXED_N entr(ies), counted while indexing -- one per .md file that produced no row." >&2
else
  echo "(none — every entry on disk produced at least one index row)" >&2
fi
echo "" >&2
echo "=== What a match costs on this tree ===" >&2
echo "Project default: JIT_CONTEXT_INJECT=$JIT_INJECT" >&2
echo "" >&2
INJ_LIST=()
for md in "$TOOLS_BASE"/*/*.md "$PATHS_BASE"/*/*.md "$VOCAB_BASE"/*/*.md; do
  [ -f "$md" ] || continue
  [ "$(basename "$md")" = "00-README.md" ] && continue
  [ -L "$(dirname "$md")" ] && continue
  INJ_LIST[${#INJ_LIST[@]}]="$md"
done
if [ "${#INJ_LIST[@]}" -eq 0 ]; then
  echo "(no entries)" >&2
else
  LC_ALL=C awk -v def="$JIT_INJECT" "$JIT_AWK_ENTRY$JIT_AWK_INJECT$JIT_AWK_REPORT_NAME"'
function relpath(p,   n, a) {
  n = split(p, a, "[/]")
  if (n < 3) return jit_report_name(p)
  return ".claude/jit-context/" jit_report_name(a[n-2]) "/" jit_report_name(a[n-1]) "/" jit_report_name(a[n])
}
function isort(v, nm, sm, ef, n,   i, j, tv, tn, ts, te) {
  for (i = 2; i <= n; i++) {
    tv = v[i]; tn = nm[i]; ts = sm[i]; te = ef[i]; j = i - 1
    while (j >= 1 && v[j] < tv) {
      v[j+1] = v[j]; nm[j+1] = nm[j]; sm[j+1] = sm[j]; ef[j+1] = ef[j]; j--
    }
    v[j+1] = tv; nm[j+1] = tn; sm[j+1] = ts; ef[j+1] = te
  }
}
BEGIN {
  n = 0
  for (ai = 1; ai < ARGC; ai++) {
    path = ARGV[ai]
    if (!jit_entry_load(path, def, 1, e)) continue
    n++
    rel = relpath(path)
    fullb[n] = length(e["body"])
    eff[n] = e["mode"]
    name[n] = rel
    keep = e["mode"]
    e["mode"] = "summary"
    sumb[n] = length(jit_inject_text(e, rel, path))
    e["mode"] = keep
    if (eff[n] == "full") { nfull++; bfull += fullb[n] }
    if (e["desc"] == "" && !(e["pin"] && e["mode"] == "full")) { nodesc++; nd[nodesc] = rel }
  }
  if (n == 0) { print "(no entries)"; exit }
  isort(fullb, name, sumb, eff, n)
  mid = int((n + 1) / 2)
  if (def == "full") {
    print "Every match injects the whole entry. Per match, on this tree:"
    print ""
    printf "  largest %7d bytes  ->  %5d summarised   %s\n", fullb[1], sumb[1], name[1]
    printf "  median  %7d bytes  ->  %5d summarised   %s\n", fullb[mid], sumb[mid], name[mid]
    printf "\n%d entr(ies) indexed.\n", n
  } else {
    printf "%d of %d entr(ies) still arrive whole, %d byte(s) between them.\n", nfull, n, bfull
    for (i = 1; i <= n && shown < 5; i++) if (eff[i] == "full") { printf "%8d  %s\n", fullb[i], name[i]; shown++ }
    if (nfull > shown) printf "         ... and %d more\n", nfull - shown
  }
  if (nodesc > 0) {
    printf "\n%d entr(ies) carry no description:, so a match could only NAME them.\n", nodesc
    for (i = 1; i <= nodesc && i <= 10; i++) print "  " nd[i]
    if (nodesc > 10) printf "  ... and %d more\n", nodesc - 10
    print "Nothing is auto-derived -- a generated summary of a wrong entry is a confident"
    print "wrong summary, and it removes the moment the author would have noticed."
  } else if (def == "full") {
    print "\nEvery entry carries a description:, so this tree can move to summary whenever"
    print "you decide the trade is worth it: JIT_CONTEXT_INJECT=summary in config.env."
  }
  print ""
  print "This is the cost of ONE match, not a total -- nothing here is ever resident, and"
  print "how often each entry fires is in .discovery/logs/hooks.log, not in this tree."
  print "A tools rule that REFUSES a call injects its whole body whatever the mode says:"
  print "the call is already stopped, so there is no next turn to spend a cheaper answer in."
}
' "${INJ_LIST[@]}" >&2
fi
echo "" >&2
case "$JIT_RC" in
  1)
    echo "rebuild-tsv: exit 1 -- the index was written, and at least one row above will be REFUSED" >&2
    echo "             by the matcher. That rule is on disk and will never fire." >&2
    ;;
  2)
    echo "rebuild-tsv: exit 2 -- an index could not be written. What is on disk is NOT what this" >&2
    echo "             run built." >&2
    ;;
esac
exit "$JIT_RC"
)
if ! CLAUDE_PROJECT_DIR="$CPD" __jit_run_rebuild_tsv_sh > /dev/null 2>&1; then
  echo "REFUSED: rebuild-tsv.sh did not complete, so the entry is on disk and inert." >&2
  echo "         Run it yourself and read what it says:" >&2
  echo "           CLAUDE_PROJECT_DIR=$CPD bash $REBUILD" >&2
  exit 1
fi
echo "indexed $BASE/vocabulary/00-manual/00-index.tsv"
echo ""
echo "It fires on a prompt about writing entries, and on nothing else. Drive it both ways:"
echo "  bash $SCRIPT_DIR/jit-dry-run.sh --base $BASE --prompt \"how do I write a jit entry\""
echo ""
echo "Then write your own beside it, and rebuild:"
echo "  CLAUDE_PROJECT_DIR=$CPD bash $REBUILD"
exit 0
