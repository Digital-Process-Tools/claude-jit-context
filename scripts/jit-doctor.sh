#!/bin/bash
# claude-jit-context -- is any of this running at all, and against which tree?
#
# The other four tools under scripts/ answer three good questions: can this pattern be
# honoured (jit-dry-run.sh), what does a match cost (rebuild-tsv.sh), what does the agent
# keep failing to find (jit-misses.sh). All three are downstream of one nobody asked.
#
# This repository own worst trap is the reason (#183). `.claude/settings.json` registers
# `enabledPlugins`, so the hooks firing in a contributor session are served from the plugin
# cache, while JIT_BASE resolves against $CLAUDE_PROJECT_DIR -- the ENTRIES are the checkout
# and the CODE reading them is not. Nothing errors. Every observable signal reports health.
#
# Usage:
#   bash scripts/jit-doctor.sh [--base DIR]
#
# --base defaults to $CLAUDE_PROJECT_DIR/.claude/jit-context -- the tree the HOOKS would
# read, which is the subject of the question, and not the tree you are standing in.
#
# Exit: 0 nothing inert | 1 a layer holds entries the matcher can never load | 2 could not
#       evaluate the tree at all. ADVISORY findings never move the exit code -- #47 has CI
#       consuming these, and failing a project over a two-character keyword is a breaking
#       change nobody filed.
#
# --- Where the line with jit-dry-run.sh falls, and why it falls there -------------------
#
# #183 asks for no second linter, and this POINTS AT that tool rather than calling it.
# Calling it would fold two verdicts into one status: doctor `1` would then mean either
# "your rules are inert" or "one pattern is unhonourable", which is the collapsed-outcome
# defect this repository is named after, arriving through the exit code. It would also make
# doctor inherit that tool per-row untrusted-text surface, and its runtime, to answer a
# question about whether anything runs at all. The two subjects are different: this one is
# "is it live", that one is "are the rules any good". So REFUSED and STALE stay there, this
# prints neither word, and the `next` section sends the reader over with the tree already
# named.
#
# --- What it does NOT claim ------------------------------------------------------------
#
# The settings scan is TEXTUAL. There is no jq in this plugin (CLAUDE.md: bash, awk, perl,
# nothing else), Claude Code merges settings from locations no script in a repository can
# enumerate, and a confident wrong answer here is worse than none -- this is the exact
# check the tool exists for, so its own third state matters more than any other line it
# prints. `cannot tell` is a first-class verdict and is not `nothing is registered`.
#
# --- One thing it creates, and it is not a verdict of its own ---------------------------
#
# It sources common.sh, which mkdir -p's $CLAUDE_PROJECT_DIR/.claude/jit-context/.discovery/
# logs when that tree already exists. jit-misses.sh refuses to source common.sh for exactly
# this reason -- a reporting tool that creates the thing it reports cannot be trusted. The
# cost is accepted here and is smaller than it looks: what gets created is a DIRECTORY, and
# every verdict below about the log is about the log FILE, which is never created. What is
# bought is jit_scan_layers() and jit_report_name(), the functions the hooks themselves use,
# so "which layers would load" is measured against the matcher rather than described.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

BASE=""
BASE_FROM=""

usage() {
  cat << 'EOF'
jit-doctor.sh -- is any of this running at all, and against which tree?

  bash scripts/jit-doctor.sh [--base DIR]

  --base DIR   the entry tree to judge. Default: $CLAUDE_PROJECT_DIR/.claude/jit-context,
               which is what the hooks read (with CLAUDE_PROJECT_DIR unset it falls
               back to the current directory).
  --help       this text.

What it reports

  tree         JIT_BASE as resolved, and what it resolved from
  hooks        which copy of the hooks would run -- the plugin cache, this checkout,
               BOTH, or `cannot tell`, which is a real answer and not a failure
  config.env   present or not, its refused lines, and the effective injection mode
  thresholds   the two ADVISORY thresholds and WHERE EACH CAME FROM, so a mistyped
               JIT_CONTEXT_DOCTOR_* key reads as a default rather than as a setting
  dimensions   per layer: entries, whether the matcher loads it, whether an index is
               there, and whether an entry is newer than it
  hook log     never ran, ran recently, or ran a while ago -- three states, not two
  advisory     short keywords, fat entries, entries with no record in the log

Outcomes

  ok, exit 0        nothing inert. ADVISORY findings do not move this.
  defect, exit 1    a layer holds entries and no index: those rules cannot fire.
  SKIPPED, exit 2   the tree could not be evaluated. The reason is named, on stderr.

It reads and prints. It writes no entry and no index.
EOF
}

# A valued flag with no value is refused in the loop, not left to `shift 2`. Under
# `set -uo pipefail` with no `-e` that shift merely fails, $1 never advances, and the loop
# spins forever having printed nothing -- #114, on four flags across two tools. Every
# refusal goes to stderr with a non-zero status, which is paths/00-manual/tooling.md
# contract: STDOUT IS THE REPORT, and a refusal captured by `jit-doctor.sh > health.txt`
# would otherwise sit in that file under no heading and read as a finding (#125).
need_value() {
  echo "jit-doctor: SKIPPED -- $1 needs a value" >&2
  echo "  run with --help for the accepted flags. Nothing was checked." >&2
  exit 2
}

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

# --- tree --------------------------------------------------------------------
# Named before one word is said about it. Every finding below is a claim about THIS
# directory, and a reader who assumes it is the one they are standing in is the reader
# #183 was filed about.
echo "tree"
printf '  %-20s %s\n' "JIT_BASE" "$BASE"
printf '  %-20s %s\n' "resolved from" "$BASE_FROM"
printf '  %-20s %s\n' "CLAUDE_PROJECT_DIR" "${CLAUDE_PROJECT_DIR:-(unset)}"
echo ""

# --- which copy of the hooks would run ---------------------------------------
# The whole reason this file exists, and the check whose THIRD STATE matters most: a
# confident wrong answer here is worse than none.
#
# The scan is textual and says so. Two markers, read independently:
#
#   enabledPlugins  a quoted key naming this plugin -- the hooks come from the cache
#   a hook command  a line naming one of this plugin's own hook scripts. If that same
#                   line also names CLAUDE_PLUGIN_ROOT or a plugins/cache path it is the
#                   cache again, wired by hand; otherwise it is a checkout.
#
# Anything else -- no readable settings file, or one that mentions neither -- is
# `cannot tell`, which is NOT "nothing is registered". Claude Code merges user, project,
# local and enterprise settings, and this script can see three of those at most.
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
  # TWO conditions, and the first draft had neither. `"claude-jit-context...":` alone
  # matched the KEY and ignored the VALUE, so a plugin explicitly turned OFF --
  # `"claude-jit-context@dpt-plugins": false` -- read as `the plugin cache serves the
  # hooks`. That is the confident wrong answer this section's own header says is worse
  # than none, in the one check the whole tool exists for.
  #
  # So the value must be `true`, and the file must mention `enabledPlugins` at all. The
  # second is what scopes the first without a JSON parser: requiring `": true"` already
  # rules out the plugin name appearing inside a hook COMMAND string, where it is part of
  # a path and never a key with a boolean after it.
  #
  # Be honest about the residue, because this scan is textual and cannot be otherwise
  # here: a `"claude-jit-context": true` sitting under some third key in a file that also
  # carries an enabledPlugins block would still count. That is a shape nobody writes, and
  # the alternative is brace-depth tracking in awk over minified JSON, which fails
  # differently and more quietly. Everything this cannot establish falls through to
  # `cannot tell`, which is the whole reason that verdict is a first-class one.
  enab=0
  if LC_ALL=C awk '/"enabledPlugins"[[:space:]]*:/ { found = 1 } END { exit !found }' "$f"; then
    enab=$(LC_ALL=C awk '/"claude-jit-context(@[^"]*)?"[[:space:]]*:[[:space:]]*true/ { n++ } END { print n + 0 }' "$f")
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

# Which cache copy, and at which version. Nothing in this repository controls the shape of
# that path, so a miss and an ambiguity are both said out loud rather than guessed at.
plugin_version() {
  # $1 a plugin root. Prints the version, routed through jit_report_name() like every
  # other value here -- it is read off a file on disk, not out of this repository.
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
  for _c in "$HOME"/.claude/plugins/cache/*/claude-jit-context \
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

# --- config.env --------------------------------------------------------------
# jit_load_config() reads and never executes -- that is what closed the config.env hole --
# but it does ASSIGN what it accepts, and a diagnostic must not take its behaviour from
# the tree it was asked to judge. So it runs in a SUBSHELL and exactly four scalars cross
# back out, each validated here before it is used or printed. jit-dry-run.sh takes the
# same shape for the same reason.
CFG="$BASE/config.env"
CFG_STATE=absent
CFG_REFUSED_N=0
TREE_INJECT=""
TREE_MAX=""
TREE_MIN=""
CFG_LINE_MAX=""
CFG_LINE_MIN=""
CFG_UNKNOWN=""

# config.env arrives with the clone, so a KEY read out of it is attacker-chosen text just
# as an entry file name is. This is jit_report_name()'s set plus the underscore, because a
# settable key carries one, and it is a function for the same reason that one is: under a
# UTF-8 locale bash own [A-Za-z0-9] admits accented letters and ${#s} counts characters
# rather than bytes, so the whole guard has to run under C collation.
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
  # Quoted: `link` is a real command on some systems, and shellcheck SC2209 is right that
  # a bare word here reads as one.
  CFG_STATE="link"
elif [ -f "$CFG" ]; then
  CFG_STATE="present"
  _cfg=$(
    # Both are reset, not just the count: jit_load_config() appends to the list and
    # increments the number, and common.sh has already run it once against the SESSION
    # config. Inheriting either would report this tree as carrying another tree lines.
    # shellcheck disable=SC2034
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
  done << EOF
$_cfg
EOF
  case "$CFG_REFUSED_N" in '' | *[!0-9]*) CFG_REFUSED_N=0 ;; esac

  # A second, tiny pass for PROVENANCE and for the typo case. jit_load_config() reports
  # neither: a JIT_CONTEXT_DOCTOR_MAX_BYTE -- singular -- parses clean, is accepted as a
  # settable key, and is never read by anything, which reads exactly like a setting that
  # applied and did nothing. No line TEXT leaves this loop, only a key and a number.
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

# --- thresholds --------------------------------------------------------------
# Both default IN THIS SCRIPT, so it works against a tree with no config.env at all, and
# both print WHERE THEY CAME FROM. That provenance is the whole point: config.env accepts
# any JIT_CONTEXT_* key without refusing it, so the only way a typo becomes visible is a
# threshold that still says (default) next to a key nobody reads.
#
# The value is VALIDATED, never trusted. `[ "$size" -gt "$junk" ]` would abort the report
# halfway through with a bash diagnostic, on a file that arrived with the clone.
MAX_BYTES=4096
MAX_FROM="(default)"
MIN_KEYWORD=3
MIN_FROM="(default)"
THRESH_REFUSED=""

# GLOBALS OUT, never `$( )`. The first draft returned the accepted value on stdout and
# appended the refusal to THRESH_REFUSED -- inside a command substitution, which is a
# SUBSHELL, so every refusal was written into a process that then exited. The report said
# `4096 (default)` and nothing else, which is precisely the silent-drop this function
# exists to prevent, reproduced inside it. tests/test-jit-doctor.sh caught it because the
# junk-value fixture asserts on the refusal TEXT and not only on the default surviving.
THRESH_VALUE=""
THRESH_FROM=""
read_threshold() {
  # $1 raw value, $2 line number, $3 key name. Sets THRESH_VALUE and THRESH_FROM on
  # acceptance; appends to THRESH_REFUSED and returns 1 otherwise.
  local raw="$1" line="$2" key="$3"
  THRESH_VALUE=""
  THRESH_FROM=""
  [ -n "$raw" ] || return 1
  case "$raw" in
    '' | *[!0-9]*)
      THRESH_REFUSED="$THRESH_REFUSED  $(printf '%-20s %s' "" "$key is not a whole number -- refused, the default stands")
"
      return 1
      ;;
  esac
  if [ "$raw" -lt 1 ]; then
    THRESH_REFUSED="$THRESH_REFUSED  $(printf '%-20s %s' "" "$key is not a whole number above zero -- refused, the default stands")
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

# --- the hook log ------------------------------------------------------------
# Three states, because "the hooks never ran here" and "they ran and matched nothing" are
# different facts that are indistinguishable today. Read BEFORE the dimensions section,
# which uses the fire counts.
LOG="$BASE/.discovery/logs/hooks.log"
LOG_STATE=absent
LOG_RECORDS=0
LOG_AGE=""
if [ -f "$LOG" ] && [ -r "$LOG" ]; then
  LOG_STATE=present
  LOG_RECORDS=$(LC_ALL=C awk 'END { print NR + 0 }' "$LOG")
  # perl, not `date -d`: the -d form is GNU-only and this runs on macOS and Git Bash too.
  # perl is already a runtime dependency of every hook here (common.sh _ts/_ms), so this
  # adds nothing. WHOLE DAYS, deliberately coarse -- a precise answer that is wrong on one
  # leg is worth less than a coarse one that is right on all three.
  LOG_AGE=$(perl -e 'printf("%d", int(-M $ARGV[0]))' "$LOG" 2> /dev/null) || LOG_AGE=""
  case "$LOG_AGE" in '' | *[!0-9]*) LOG_AGE="" ;; esac
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
    printf '  %-20s %s\n' "last written" "cannot tell -- no perl here to read the timestamp"
  elif [ "$LOG_AGE" -lt 1 ]; then
    printf '  %-20s %s\n' "last written" "today"
  else
    printf '  %-20s %s\n' "last written" "$LOG_AGE days ago"
  fi
fi
echo ""

# --- dimensions, layers, entries and indexes ---------------------------------
# jit_scan_layers() is the function the three hooks call, sourced from the common.sh they
# source, run here against the tree being judged. A layer in its list is a layer the code
# ON THIS DISK opens -- measured, not documented (#176).
JIT_LAYERS_REFUSED=""
JIT_LAYERS_REFUSED_N=0

ENTRY_KEY=()
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
    for _md in "$_d"/*.md; do
      [ -f "$_md" ] || continue
      _md_n=$((_md_n + 1))
      [ -f "$_idx" ] && [ "$_md" -nt "$_idx" ] && _stale=1
      _name="${_md##*/}"
      # THE LOG KEY IS NOT THE DISPLAY LABEL, and the two dimensions spell it differently.
      # pre-path-hook.sh and the vocabulary half of pre-tool-hook.sh write `layer:file.md(`
      # -- but the TOOLS half writes the literal `tool:file.md(` and never the layer name
      # (the four `"tool:" r_logname` appends in the tools loop of pre-tool-hook.sh: the
      # two BLOCKED ones for require and forbid, the `[full:block]` one, and the advisory
      # one that builds `log_adv`). Keyed on the layer for all three, every
      # tools entry came back with a fire count of zero and was reported `never fired`
      # however often it had actually matched: an absence produced by this tool, reported
      # as an absence in the world, in the section written to end exactly that.
      case "$_dim" in
        tools) _key="tool:$_name" ;;
        *) _key="$_layer:$_name" ;;
      esac
      case "$_key" in *"$JIT_NL"*) _key="<unnameable>" ;; esac
      ENTRY_KEY[$ENTRY_N]="$_key"
      ENTRY_LABEL[$ENTRY_N]="$_dim/$_safe"
      ENTRY_NAME[$ENTRY_N]="$(jit_report_name "$_name")"
      ENTRY_BYTES[$ENTRY_N]=$(LC_ALL=C awk 'END { print n + 0 } { n += length($0) + 1 }' "$_md")
      ENTRY_N=$((ENTRY_N + 1))
    done
    _note=""
    if [ ! -f "$_idx" ]; then
      if [ "$_md_n" -gt 0 ]; then
        # EXACT, and the one thing here that is a defect rather than a hint: the hooks
        # read 00-index.tsv and nothing else, so every rule in this layer is inert.
        _note="no index -- every rule in this layer is inert, run scripts/rebuild-tsv.sh"
        DEFECTS=$((DEFECTS + 1))
      else
        _note="no index, and no entries either"
      fi
    elif [ "$_stale" = 1 ]; then
      # ADVISORY and not a defect, on purpose. mtime is a PROXY: a fresh clone writes
      # 00-index.tsv before the .md files beside it, so this accuses a tree that is
      # perfectly current. jit-dry-run.sh compares the frontmatter against the row and
      # owns that verdict; this only says where to look.
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
  # A dimension directory that exists and holds no layer directory printed NOTHING: the
  # glob stays literal with no nullglob, the `[ -d ]` drops it, and the loop body never
  # runs. So the dimension simply did not appear under this heading -- which is what a
  # scan that died halfway would also look like, and is the same collapsed pair the
  # missing-dimension branch above was careful to keep apart.
  if [ "$_rows" = 0 ]; then
    printf '  %-24s %s\n' "$_dim/" "no layer directory under it -- there is nothing here to load"
  fi
done
unset _dim _d _layer _safe _idx _md _md_n _stale _name _key _note _loads _read _rows
if [ "$JIT_LAYERS_REFUSED_N" -gt 0 ]; then
  # By position and never by name, the rule the hooks own notice follows: a layer
  # directory name arrives with the clone.
  printf '  %s\n' "$JIT_LAYERS_REFUSED_N layer director(y/ies) exist and the matcher does not read:"
  printf '%s\n' "$JIT_LAYERS_REFUSED" | sed 's/^/    /'
  printf '  %s\n' "Nothing inside them can fire. jit-dry-run.sh prints the same list with its lint."
fi
echo ""

# --- how often each entry fired ----------------------------------------------
# One awk pass over the log for every entry at once, rather than one grep per entry: a
# 1,000-entry tree against a 2 MB log is the case this has to stay usable in. The keys go
# in on stdin and come back out IN ORDER, one count per line, so nothing here needs an
# associative array -- macOS ships bash 3.2 and does not have them.
FIRED=()
if [ "$LOG_STATE" = present ] && [ "$ENTRY_N" -gt 0 ]; then
  _counts=$(printf '%s\n' "${ENTRY_KEY[@]}" | LC_ALL=C awk '
    FNR == NR { order[++nk] = $0; next }
    {
      p = index($0, " | ")
      if (p == 0) next
      rest = substr($0, p + 3)
      q = index(rest, " << ")
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
  done << EOF
$_counts
EOF
  unset _counts _i _c
fi

# --- the advisory heuristics -------------------------------------------------
# Every one of these is ADVISORY and none moves the exit code. #47 has CI consuming these
# codes; failing every project that carries a two-character keyword is a breaking change
# nobody filed, and a `--strict` flag is the place for that if anyone wants it.
#
# Fat entries are a FLAT byte count, not weighted by how often the entry fires -- flat is
# honest and dumb, and the fire count is printed BESIDE it so the reader judges rather
# than the tool guessing.
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

# "Never fired despite existing for N days" is what #183 asks for and this deliberately
# does NOT claim the second half. hooks.log records carry a TIME and no date, and an entry
# mtime is rewritten by every clone and every checkout -- so "for N days" is not computable
# from anything this repository keeps, and a threshold built on either would be a confident
# number with nothing under it. What IS observable is stated, and no more than that.
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

# Short keywords, read off the vocabulary indexes -- the index is what the hook matches
# against, so a keyword that is not in there is not a keyword. The term is guarded by
# jit_report_keyword(), NOT jit_report_name(): `vat rate` is a legitimate keyword and the
# name set has no space in it (#126).
# vocabulary alone, and not a loop over the three: a `match` is a pattern and a tools row
# carries a tool name, so "shorter than N bytes" is a claim only about a KEYWORD. A
# for-loop over one word would say otherwise, and shellcheck SC2043 is right to ask.
#
# IN A FUNCTION, so `local LC_ALL=C` holds for every ${#kw} inside it and is restored on
# return. That is not tidiness. ${#s} in bash counts CHARACTERS under a UTF-8 locale and
# BYTES under C, the threshold is documented in bytes, and jit_report_name() carries the
# same `local LC_ALL=C` for the same reason one function up. Unpinned, a two-character
# accented keyword measures 2 here and 4 in the index the hook reads.
scan_short_keywords() {
  local LC_ALL=C dim=vocabulary d safe row kw ent
  [ -d "$BASE/$dim" ] || return 0
  for d in "$BASE/$dim"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    safe="$(jit_report_name "${d##*/}")"
    [ -f "$d/00-index.tsv" ] && [ -r "$d/00-index.tsv" ] || continue
    # The rows come through awk rather than straight into `read -r`, because `read -r`
    # truncates a row at a NUL -- the trap paths/00-manual/tooling.md records for the
    # byte checks.
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      kw="${row%%	*}"
      # #232 added a third column (the generic/specific verdict) to this same TSV, so
      # "everything after the first tab" -- what this line read until now -- has grown
      # a trailing "\tgeneric" or a bare trailing tab on any 3-column row. That extra
      # tab is exactly the byte jit_report_name() below refuses on sight, so this
      # advisory silently started printing "<withheld: not a plain name>" for every
      # short keyword in a rebuilt tree instead of the file it actually lives in.
      # Second field only, whatever the row's total column count is now or grows to.
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
printf '  %s\n' "bash scripts/jit-dry-run.sh --base $BASE"
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
