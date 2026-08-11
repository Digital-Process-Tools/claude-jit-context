#!/bin/bash
# Shared functions for claude-jit-context hooks and pipeline scripts.
# Source this at the top of every script: source "$(dirname "$0")/common.sh"

_ms() { perl -MTime::HiRes -e 'printf("%.0f\n",Time::HiRes::time()*1000)'; }

JIT_BASE="${CLAUDE_PROJECT_DIR:-.}/.claude/jit-context"

LOG_DIR="$JIT_BASE/.discovery/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/hooks.log"

# Timestamp with ms precision (single perl call, ~11ms)
_ts() { perl -MTime::HiRes -MPOSIX -e 'my $t=Time::HiRes::time(); printf("%s.%03d\n", strftime("%H:%M:%S",localtime($t)), ($t*1000)%1000)'; }

# --- Optional per-project settings ------------------------------------------
# config.env lives INSIDE the project, so it arrives with the repository. It used to be
# dot-sourced here, on every prompt and every tool call, which made cloning a repo and
# opening it arbitrary code execution before the user had read a line of the code.
# Reproduced 2026-08-11: a config.env of `echo ... >&2` printed, and one of `touch ...`
# created the file.
#
# Every documented setting is a plain KEY=VALUE, so the file is READ and never executed.
#
# Only the three documented prefixes are settable. A bare identifier allowlist is not
# enough: PATH is a valid identifier, common.sh runs before every hook invokes `awk`, and
# a config.env that could set PATH would be the same execution one hop removed.
#
# A line that cannot be honoured is REFUSED and named -- in the log, and once per session
# in the injected context. A silently dropped setting is this repo's own defect class: it
# reads exactly like a setting that applied and did nothing.
#
# Only the line number and the reason are reported, never the line's own text. The premise
# of the whole change is that this file may be hostile, and hostile text does not belong
# in a model's context.
#
# The list travels to the hooks through the ENVIRONMENT, never through `awk -v`. It is
# newline-separated, and a -v value containing a newline is the fatal awk error "newline
# in string" -- raised before the program runs, so the hook printed nothing at all and
# exited 0. A single refused line has no separator and hid that completely; two lines
# silenced the whole hook. The channel for reporting a silent failure must not have one.
export JIT_CONFIG_REFUSED=""
export JIT_CONFIG_REFUSED_N=0

jit_load_config() {
  local file="$1" line key value reason q rest tail lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # A CRLF checkout must parse the same as an LF one -- config.env is not covered by
    # this repo's .gitattributes, because it lives in the user's project.
    line="${line%$'\r'}"
    while [ "$line" != "${line#[[:space:]]}" ]; do line="${line#[[:space:]]}"; done
    case "$line" in
      ''|'#'*) continue ;;
      # `export KEY=VALUE` was valid while this file was sourced, so it stays valid.
      # The export itself is a no-op now: the hooks read these as shell variables.
      export[[:space:]]*)
        line="${line#export}"
        while [ "$line" != "${line#[[:space:]]}" ]; do line="${line#[[:space:]]}"; done
        ;;
    esac

    reason=""
    case "$line" in
      *=*) key="${line%%=*}"; value="${line#*=}" ;;
      *)   key=""; value=""; reason="not a KEY=VALUE assignment" ;;
    esac
    if [ -z "$reason" ] && ! [[ "$key" =~ ^(JIT_CONTEXT|DYNAMIC_RULES|DVSI)_[A-Za-z0-9_]+$ ]]; then
      reason="unknown setting (only JIT_CONTEXT_*, DYNAMIC_RULES_* and DVSI_* are read)"
    fi
    if [ -n "$reason" ]; then
      JIT_CONFIG_REFUSED_N=$((JIT_CONFIG_REFUSED_N + 1))
      JIT_CONFIG_REFUSED="$JIT_CONFIG_REFUSED${JIT_CONFIG_REFUSED:+$'\n'}- line $lineno: $reason"
      continue
    fi

    # Quotes and trailing comments are handled the way `.`-sourcing handled them, because
    # a config.env that worked before this change has to keep working. A parser that only
    # strips a quote pair turns `KEY="src/" # default` into the value `"src/" # default`
    # -- not refused, not reported, just quietly wrong. That is the exact failure mode the
    # refusal machinery above exists to prevent, reintroduced by the fix for it.
    #
    # Nothing inside a value is expanded: a $, a backtick or a $(...) is a literal now.
    case "$value" in
      '"'*|"'"*)
        q="${value%"${value#?}"}"        # the opening quote, " or '
        rest="${value#?}"
        case "$rest" in
          *"$q"*)
            tail="${rest#*"$q"}"
            while [ "$tail" != "${tail#[[:space:]]}" ]; do tail="${tail#[[:space:]]}"; done
            case "$tail" in
              # Anything after the closing quote that is not a comment is ambiguous, so it
              # is refused rather than guessed at. Guessing is how a value goes quietly
              # wrong, which is the one outcome this whole function is written to avoid.
              ''|'#'*) value="${rest%%"$q"*}" ;;
              *) reason="trailing text after the closing quote" ;;
            esac
            ;;
          *) reason="unterminated quote" ;;
        esac
        ;;
      *)
        # Bash starts a comment at a # preceded by whitespace, and treats one that is not
        # as an ordinary character -- so `^(a#b)$` keeps its hash and `1 # on` does not.
        case "$value" in
          *[[:space:]]#*) value="${value%%[[:space:]]#*}" ;;
        esac
        while [ "$value" != "${value%[[:space:]]}" ]; do value="${value%[[:space:]]}"; done
        ;;
    esac
    if [ -n "$reason" ]; then
      JIT_CONFIG_REFUSED_N=$((JIT_CONFIG_REFUSED_N + 1))
      JIT_CONFIG_REFUSED="$JIT_CONFIG_REFUSED${JIT_CONFIG_REFUSED:+$'\n'}- line $lineno: $reason"
      continue
    fi
    printf -v "$key" '%s' "$value"
  done < "$file"
}

if [ -f "$JIT_BASE/config.env" ]; then
  jit_load_config "$JIT_BASE/config.env"
  if [ "$JIT_CONFIG_REFUSED_N" -gt 0 ]; then
    printf '[%s] config.env | %d line(s) refused\n%s\n' \
      "$(_ts)" "$JIT_CONFIG_REFUSED_N" "$JIT_CONFIG_REFUSED" >> "$LOG_FILE"
  fi
fi

# Pipeline log: _log "step" duration_ms "message"  → [HH:MM:SS.mmm] step 42ms | message
_log() {
  local line="$1 ${2}ms | $3"
  echo "[$(_ts)] $line" >> "$LOG_FILE"
  echo "$line"
}

# --- Shared awk guard for a rule match pattern -------------------------------
# Prepended to the hook programs (awk "$JIT_AWK_GUARD"'...'), so the same verdict is
# reached by pre-tool-hook.sh, pre-path-hook.sh and jit-dry-run.sh.
#
# Two failures, and only one of them is loud:
#
#   1. An undefined escape. Measured 2026-08-10 on awk version 20200816: of the ASCII
#      letters, only \a \b \f \n \r \t \v \x survive; every other \<letter> compiles to
#      the bare letter, so ~gh\s+pr becomes ghs+pr and matches nothing at all. awk does
#      not fail on this. It exits 0. Exit status cannot see this defect, which is why
#      the check here is structural rather than a compile probe.
#   2. A malformed pattern. ~a[b is a fatal awk error (exit 2) raised mid-scan, so the
#      END block never runs and EVERY rule in that index — plus the vocabulary pass and
#      the log line — is silenced by one row. Reproduced against both hooks.
#
# The verdict is deliberately engine-independent. A rule fires on the author machine,
# which is where the drop happens; gawk accepting \s is not a licence to write it, and a
# lint whose answer changes with the runner cannot gate anything.
#
# \n is the one escape rules genuinely need — it anchors on command position,
# (^|[;&|\n] *), because ^ anchors the whole command string and not each line. \t and \r
# are honoured too and are left alone. Everything else after a backslash that is a letter
# or a digit is refused: the author is present, and the fix is one character.
#
# Returns "" when the pattern can be honoured, else a short reason.
# Consumed by the hook awk programs and jit-dry-run.sh, which shellcheck cannot see.
# shellcheck disable=SC2034
JIT_AWK_GUARD='
function jit_bad_pattern(p,   i, n, c, nx, depth, inbr, brpos) {
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
      i++
      continue
    }
    if (inbr) {
      # A POSIX class, collating element or equivalence class is one unit, and the ] it
      # contains does NOT close the bracket expression. Scanning ] naively reads
      # [[:alnum:] as balanced and hands it to match(), where it is a FATAL awk error --
      # reopening the exact failure this guard exists to stop.
      if (c == "[" && substr(p, i + 1, 1) ~ /^[:.=]$/) {
        k = index(substr(p, i + 2), substr(p, i + 1, 1) "]")
        if (k == 0) return "unterminated [" substr(p, i + 1, 1) " element inside a character class"
        i = i + 2 + k
        continue
      }
      # ] is a literal when it is the first character of the expression, or the first
      # after a negating ^.
      if (c == "]" && i != brpos + 1 && !(i == brpos + 2 && substr(p, brpos + 1, 1) == "^")) inbr = 0
      continue
    }
    if (c == "[") { inbr = 1; brpos = i; continue }
    if (c == "(") { depth++; continue }
    # An unmatched ) is a LITERAL in an ERE and awk accepts it -- measured, a)b matches.
    # Refusing it would kill rules that work today, which is worse than the bug: this
    # guard may only ever refuse a pattern awk cannot honour. An unmatched ( is a fatal
    # error, so the closing check below is deliberately one-sided.
    if (c == ")") { if (depth > 0) depth--; continue }
  }
  if (inbr) return "unterminated character class"
  if (depth > 0) return "unbalanced parenthesis"
  return ""
}
'

# --- Shared awk containment check + refusal notices ---------------------------
# Prepended to all three hook programs (the prompt hook has no patterns to guard, so it
# takes this and not JIT_AWK_GUARD), and to jit-dry-run.sh.
#
# An index row names its entry file, and every hook builds the path by concatenating that
# name onto the layer directory. Until 2026-08-11 nothing checked it, so a committed row
# of `../../../../outside.txt` made the hook READ that file and inject its contents into
# the model's context. 00-index.tsv is a committed file, so cloning a repository was the
# whole attack. Reproduced at all five read sites: the path rule loop, the tool rule loop,
# and the three vocabulary passes.
#
# The check is "a bare file name", not a resolved-prefix comparison, because awk has no
# realpath and shelling out for one would cost a process per row. It is safe to be this
# strict: rebuild-tsv.sh writes this column with `basename` at all four of its sites, and
# the generated-layer contract in the README is the same TSV format, so a name carrying a
# separator was never produced by this project.
#
# The backslash is refused for Windows. On Git Bash the Win32 file API underneath awk
# treats it as a separator, so `..\..\x` traverses there while being inert here -- the
# reverse of the mistake this repo has already made twice about the other legs of CI.
#
# Consumed by the hook awk programs and jit-dry-run.sh, which shellcheck cannot see.
# shellcheck disable=SC2034
JIT_AWK_ENTRY='
# A refused row is reported by POSITION, never by the text of its file-name column. That
# column is attacker-controlled free text whose only constraint is that it carries a
# separator, and the refusal notice fires without any rule having matched -- so echoing it
# back would be a prompt-injection channel that needs no trigger at all. The full name
# still goes to hooks.log, which a person reads and no model does.
function jit_row_id(layer, rown) {
  return layer " row " rown
}
function jit_bad_entry_file(f) {
  # An empty column is a blank index line, not a rule. It carries no pattern either and
  # the caller skips it on the existing content == "" path; refusing it would fire a
  # notice at the author over stray whitespace.
  if (f == "") return ""
  if (index(f, "/") > 0 || index(f, "\\") > 0) return "not a bare file name"
  if (f == "." || f == "..") return "not a bare file name"
  return ""
}
function jit_refusal_notice(list, n) {
  return "# JIT Context: " n " rule(s) could not be evaluated, so they did NOT run\n" list \
    "\nA pattern the matcher cannot honour is not a rule that did not match, and until now the two looked identical. Lint the tree that owns these rules:\n  bash scripts/jit-dry-run.sh --base <tree>/.claude/jit-context"
}
function jit_config_notice(list, n) {
  return "# JIT Context: " n " line(s) in .claude/jit-context/config.env were refused, so they did NOT take effect\n" list \
    "\nconfig.env is read as plain KEY=VALUE and is never executed. Only JIT_CONTEXT_*, DYNAMIC_RULES_* and DVSI_* settings are read; anything else, shell included, is refused. If a refused line is not one you wrote, treat that file as hostile -- it arrived with the repository."
}
'

# --- Shared JSON string reader ---------------------------------------------
# Prepended to all three hook programs. Every hook used to read its payload with
# `split(input, f, "\\"")` and take the raw field, which is wrong twice:
#
#   1. It ends a value at the first ESCAPED quote. `gh pr list --search \\"a b\\" --limit 20`
#      arrived as `gh pr list --search ` -- so a `require: --limit` blocked a command that
#      carried --limit, and only when the flag sat after the quote. The require check is a
#      plain index(); it was the subject that had been cut, not the test.
#   2. It never decodes anything. A multi-line Bash command arrives with its newlines as
#      the two characters \\ and n, so a rule anchored `~(^|[;&|\\n] *)` -- where the escape
#      is a real newline to awk -- could not fire on it, ever. Nothing errored, nothing
#      warned; the rule read as enforced and was not.
#
# jit_json_fields() keeps the old quote-split parity (field[even] = key, field[even+2] =
# value) but reports each field as a RANGE of raw pieces, rejoining nothing: a quote whose
# preceding piece ends in an odd number of backslashes was escaped, so it is content and
# the field continues past it.
#
# Ranges rather than strings, because a Write payload carries the whole file body in
# tool_input.content and every literal quote in that body arrives escaped. Concatenating a
# field back together costs a copy of the whole value per escaped quote — measured at
# 359 ms for a 200 KB payload with 8000 of them, against 30 ms before and 44 ms now.
# jit_field()
# materialises a field only when a caller asks for one, and a caller only ever asks for
# the four short values it matches on.
#
# Parity is read off the single piece before the quote, never the joined field: a join
# always inserts a literal quote, so a run of backslashes can never carry across one.
#
# An escape awk cannot represent is left exactly as written rather than swallowed: eating
# the backslash of an unknown escape would turn `\\d` into `d` and hand the matcher a
# subject its author never typed. \\uXXXX is in that set deliberately -- decoding it needs
# UTF-8 assembly no awk here can be trusted to do.
# shellcheck disable=SC2034
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
    # An odd number of trailing backslashes means the quote that follows was escaped, so
    # it is content and not a delimiter: the field runs on. The backslash stays put and
    # jit_unescape() collapses the pair when the field is finally materialised.
    if (jit_trailing_backslashes(raw[i]) % 2 == 1) continue
    fe[k] = i
    k++
    fs[k] = i + 1
  }
  fe[k] = n
  return k
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

# Hook log with timing + matches: _log_hook "pre-tool (Bash)" 42 "tool:git-push.md(git push)"
_log_hook() {
  local hook="$1"
  local ms="$2"
  local matches="${3:-(none)}"
  echo "[$(_ts)] $hook ${ms}ms | $matches" >> "$LOG_FILE"
}
