#!/usr/bin/env python3
"""Compile every shipped jit-context script that loads another file into one
self-contained file (#461).

The Anthropic directory validator refuses to follow a script that `source`s or
runs a further file it has not itself read (COMMAND_SCRIPT_NOT_FOLLOWED): every
hook `source`s scripts/common.sh, common.sh itself sources common-awk.sh and
host.sh, session-start-hook.sh and jit-stats.sh run jit-misses.sh as a
subprocess, and jit-init.sh runs rebuild-tsv.sh the same way.

`main` keeps the commented, multi-file layout unchanged -- this module only
runs at BUILD time, against the in-memory {path: bytes} map
build_release_tree.py already holds before it writes the release tree to disk.

What it does, in order:

1. Inline scripts/host.sh and scripts/common-awk.sh into scripts/common.sh,
   replacing the two `[ -r FILE ] && source FILE` guards with the library's own
   body (its shebang dropped) -- the guard existed so a MISSING file degrades
   instead of crashing a hook; a file baked into the same script can never be
   missing, so the guard becomes dead weight and is removed along with the
   now-impossible failure path it protected. `source FILE; A && B` and the
   literal statements of FILE followed by `A && B` have the identical exit
   status (bash runs a sourced file's statements in the current shell exactly
   as if they were typed inline), so this substitution changes nothing a
   caller can observe.
2. Splice that self-contained common.sh into every script that sources it
   (the six hooks, jit-stats.sh, rebuild-tsv.sh, jit-doctor.sh, jit-match.sh,
   jit-dry-run.sh), replacing their own `source`/`.` line.
3. Wrap jit-misses.sh (a leaf -- it loads nothing else) and the now
   self-contained rebuild-tsv.sh as functions defined with a `()` (subshell)
   body, so a call has the same argv/stdout/stderr/exit semantics as
   `bash that-script.sh "$@"`: a subshell function's own `exit` ends the
   subshell, never the caller, exactly like a real child process, and
   `VAR=value a_function` exports VAR for that one call exactly like it would
   for an external command. Each caller's `bash "$SCRIPT_DIR/other.sh" ...`
   call site is rewritten to call the wrapper function instead, and the
   wrapper definition is inserted right after the caller's own shebang line.
4. Strips whole-line comments and blank lines from the fully assembled text of
   every script this module touches (never jit-misses.sh, which has nothing to
   inline and ships byte-identical to main). Conservative by construction: a
   line is only ever dropped when the scanner can PROVE, by tracking bash
   quoting state across the whole file, that it is sitting outside every
   single- and double-quoted string. The one exception is also provable rather
   than guessed: a `JIT_AWK_*='...'` block is this codebase's own documented
   awk-program-as-bash-string convention (common-awk.sh's own header: "eleven
   JIT_AWK_* variables, each holding one chunk of awk source"), so a bare
   `#...`-only line inside one of THOSE specific single-quoted blocks is a
   real awk comment and is dropped too. Every other multi-line string (help
   text, printf payloads) is left untouched, blank lines and `#`-leading data
   lines included, because nothing proves those are comments rather than
   output a user is meant to see.

LIBRARY_FILES (common.sh, common-awk.sh, host.sh) are returned separately so
build_release_tree.py can drop them from the tree: once every caller has its
own copy, nothing loads them by path any more, and a file nothing loads is
exactly the ballast the deny-list exists to remove.
"""

from __future__ import annotations

import re

LIBRARY_FILES = {
    "scripts/common.sh",
    "scripts/common-awk.sh",
    "scripts/host.sh",
}

# Every script that `source`s/`.`s common.sh, and the exact line to replace.
# rebuild-tsv.sh alone resolves it via `$(dirname "$0")` rather than
# `$SCRIPT_DIR` -- both forms are matched explicitly rather than guessed at,
# so a future script written with a third spelling fails the guard (and this
# module's own self-check below) instead of silently shipping unsourced.
_COMMON_SOURCE_LINES = [
    'source "$SCRIPT_DIR/common.sh"',
    '. "$SCRIPT_DIR/common.sh"',
    'source "$(dirname "$0")/common.sh"',
]

# path -> (subprocess call text to replace, wrapper function name, library
# path whose SELF-CONTAINED (already common.sh-inlined where relevant) body
# becomes the function's subshell).
_SUBPROCESS_CALLS = {
    "scripts/session-start-hook.sh": [
        ('bash "$SCRIPT_DIR/jit-misses.sh"', "__jit_run_jit_misses_sh",
         "scripts/jit-misses.sh"),
    ],
    "scripts/jit-stats.sh": [
        ('bash "$SCRIPT_DIR/jit-misses.sh"', "__jit_run_jit_misses_sh",
         "scripts/jit-misses.sh"),
    ],
    "scripts/jit-init.sh": [
        ('bash "$REBUILD"', "__jit_run_rebuild_tsv_sh",
         "scripts/rebuild-tsv.sh"),
    ],
}

_SHEBANG_RE = re.compile(r"^#![^\n]*\n")


def _drop_shebang(text: str) -> str:
    return _SHEBANG_RE.sub("", text, count=1)


class CompileError(Exception):
    """The compiler could not prove it produced an equivalent script."""


# -- step 1: fold host.sh and common-awk.sh into common.sh ------------------

_HOST_GUARD_OLD = '''case "${BASH_SOURCE[0]}" in
  */*) _jit_host_sh="${BASH_SOURCE[0]%/*}/host.sh" ;;
  *) _jit_host_sh="./host.sh" ;;
esac
if [ -r "$_jit_host_sh" ]; then
  # shellcheck disable=SC1090
  source "$_jit_host_sh" 2> /dev/null \\
    && JIT_HOST="$(jit_host_detect 2> /dev/null)" \\
    && JIT_HOST_REFUSAL_STATE="$(jit_host_refusal_state "$JIT_HOST" 2> /dev/null)"
  [ -n "$JIT_HOST" ] || JIT_HOST="unknown"
  [ -n "$JIT_HOST_REFUSAL_STATE" ] || JIT_HOST_REFUSAL_STATE="refusal-not-established"
  # Deliberately its OWN command substitution, not chained onto the `&&` above: the
  # alias table must still be computed even when jit_host_detect()/jit_host_refusal_state()
  # somehow failed (an empty $JIT_HOST is a real, expected case -- see column 8's own
  # comment in host.sh), so this must not go dark just because an earlier link in that
  # chain did.
  JIT_TOOL_ALIASES="$(jit_all_tool_aliases 2> /dev/null)"
  [ -n "$JIT_TOOL_ALIASES" ] || JIT_TOOL_ALIASES=""
fi
export JIT_HOST JIT_HOST_REFUSAL_STATE JIT_TOOL_ALIASES
unset _jit_host_sh'''

_COMMON_AWK_GUARD_OLD = '''case "${BASH_SOURCE[0]}" in
  */*) _jit_common_awk_sh="${BASH_SOURCE[0]%/*}/common-awk.sh" ;;
  *) _jit_common_awk_sh="./common-awk.sh" ;;
esac
if [ -r "$_jit_common_awk_sh" ]; then
  # shellcheck disable=SC1090
  source "$_jit_common_awk_sh" 2> /dev/null
fi
unset _jit_common_awk_sh'''


def build_inlined_common_sh(common_sh: str, common_awk_sh: str, host_sh: str) -> str:
    """scripts/common.sh with host.sh and common-awk.sh folded in, each exactly
    once. Raises CompileError if either guard text has drifted out from under
    this module -- a silent no-op here would ship a hook that still points at
    a file the release tree no longer carries."""
    host_new = _drop_shebang(host_sh).rstrip("\n") + (
        '\nJIT_HOST="$(jit_host_detect 2> /dev/null)" \\\n'
        '  && JIT_HOST_REFUSAL_STATE="$(jit_host_refusal_state "$JIT_HOST" 2> /dev/null)"\n'
        '[ -n "$JIT_HOST" ] || JIT_HOST="unknown"\n'
        '[ -n "$JIT_HOST_REFUSAL_STATE" ] || JIT_HOST_REFUSAL_STATE="refusal-not-established"\n'
        'JIT_TOOL_ALIASES="$(jit_all_tool_aliases 2> /dev/null)"\n'
        '[ -n "$JIT_TOOL_ALIASES" ] || JIT_TOOL_ALIASES=""\n'
        "export JIT_HOST JIT_HOST_REFUSAL_STATE JIT_TOOL_ALIASES"
    )
    if _HOST_GUARD_OLD not in common_sh:
        raise CompileError(
            "common.sh: the host.sh source guard has changed shape -- "
            "update _HOST_GUARD_OLD in compile_scripts.py")
    out = common_sh.replace(_HOST_GUARD_OLD, host_new, 1)

    awk_new = _drop_shebang(common_awk_sh).rstrip("\n")
    if _COMMON_AWK_GUARD_OLD not in out:
        raise CompileError(
            "common.sh: the common-awk.sh source guard has changed shape -- "
            "update _COMMON_AWK_GUARD_OLD in compile_scripts.py")
    out = out.replace(_COMMON_AWK_GUARD_OLD, awk_new, 1)
    return out


def inline_common_sh(script: str, inlined_common_sh: str, script_path: str) -> str:
    body = _drop_shebang(inlined_common_sh).rstrip("\n")
    for line in _COMMON_SOURCE_LINES:
        if line in script:
            return script.replace(line, body, 1)
    raise CompileError(
        f"{script_path}: none of the known common.sh source lines were found -- "
        "update _COMMON_SOURCE_LINES in compile_scripts.py")


def wrap_as_function(name: str, body: str) -> str:
    """A subshell-bodied function: `name() ( ...body... )`. Called with
    `name "$@"` it has the same argv, stdout, stderr and exit-status contract
    as `bash original-script.sh "$@"` -- `exit` inside a `()` body ends the
    subshell, not the caller, and `VAR=val name ...` exports VAR for that one
    call the same way it would for `VAR=val bash original-script.sh ...`."""
    return f"{name}() (\n{body.rstrip(chr(10))}\n)"


def inline_subprocess_call(script: str, call_text: str, func_name: str,
                            func_body: str, script_path: str,
                            count: int = 1) -> str:
    if call_text not in script:
        raise CompileError(
            f"{script_path}: subprocess call {call_text!r} not found -- "
            "update _SUBPROCESS_CALLS in compile_scripts.py")
    wrapper = wrap_as_function(func_name, _drop_shebang(func_body))
    # Defined immediately before the FIRST call site, never after the
    # shebang: jit-init.sh's own usage() reads its own header comment block
    # off "$0" at call time (see _usage_structural_end_line below), and a
    # multi-thousand-line wrapper inserted ahead of line 1 pushes that whole
    # header past the point a FIXED protect_until was computed against,
    # leaving it unprotected from strip_comments() even though nothing about
    # the header itself changed -- reproduced empirically (#461) before this
    # was changed from "after the shebang" to "before the call site".
    idx = script.index(call_text)
    line_start = script.rfind("\n", 0, idx) + 1  # 0 if call_text is on line 1
    script = script[:line_start] + wrapper + "\n" + script[line_start:]
    return script.replace(call_text, func_name, count)


# -- step 4: comment / blank-line stripping ----------------------------------

# Two shapes name an awk-program-as-bash-string, not one: a bare
# `JIT_AWK_NAME='` assignment (common-awk.sh, eleven of these -- its own header
# documents the convention), and this codebase's other one, a CONCATENATION
# that composes several of those onto the end of a plain double-quoted prefix
# before opening a trailing single quote on the same line, e.g.
# `JIT_AWK_PROGRAM="$JIT_AWK_GUARD$JIT_AWK_ENTRY..."\'` or
# `awk "$JIT_AWK_JSON"\'` (pre-tool-hook.sh, post-tool-hook.sh, stop-hook.sh,
# session-start-hook.sh, pre-prompt-hook.sh, jit-match.sh, jit-dry-run.sh,
# rebuild-tsv.sh all do this at least once). Both shapes are provable from the
# SAME piece of textual evidence this codebase already commits to: the
# variable name on the line carries the substring AWK. A line with no such
# name opening a quote is left alone, same as any other multi-line string.
_AWK_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*AWK[A-Za-z0-9_]*")


def strip_comments(text: str, protect_until: int = 0) -> str:
    """Drop whole-line bash comments and blank lines from CODE (unquoted)
    context, plus whole-line comments inside a documented awk-source
    single-quoted block (see _AWK_NAME_RE above for the two shapes this
    matches). Never touches the shebang, a trailing comment, or any other
    multi-line string. A heredoc body is not special-cased: none of the 16
    shipped scripts under scripts/ contain a real `<<WORD` heredoc operator
    today (#459 replaced the last ones with here-strings and printf) --
    `<<<` here-strings are a single token on one line and need no multi-line
    state at all. If that ever stops being true, test-release-branch-461.sh's
    equivalence run is what catches it, by failing on a heredoc operator
    stripped mid-body.

    protect_until (1-indexed physical line count): lines [1, protect_until]
    are NEVER dropped, no matter what the scan below would otherwise decide
    -- only their characters still update the running quote state, so a
    quoted string that opens inside the protected region and closes after it
    is still tracked correctly. This exists for scripts/jit-dry-run.sh and
    scripts/jit-match.sh: each has a `usage() { sed -n "N,Mp" "$0"; }` that
    prints its own on-disk header comment block as --help text (jit-dry-run.sh
    even comments "a line added above this shifts it and truncates silently"
    about exactly this fragility) -- stripping a comment out of that block
    changes what --help prints, a real behavior change rather than the inert
    ballast this function exists to remove everywhere else.
    """
    lines = text.split("\n")
    out = []
    state = "CODE"  # CODE | SINGLE | DOUBLE
    in_awk_single = False

    for idx, line in enumerate(lines):
        if idx == 0 and line.startswith("#!"):
            out.append(line)
            continue

        start_state = state
        start_awk = in_awk_single
        i, n = 0, len(line)
        comment_at = None
        open_col = None

        while i < n:
            c = line[i]
            if state == "SINGLE":
                if c == "'":
                    state = "CODE"
                    in_awk_single = False
                i += 1
                continue
            if state == "DOUBLE":
                if c == "\\\\" and i + 1 < n:
                    i += 2
                    continue
                if c == '"':
                    state = "CODE"
                i += 1
                continue
            # state == CODE
            if c == "\\\\" and i + 1 < n:
                i += 2
                continue
            if c == "'":
                state = "SINGLE"
                open_col = i
                i += 1
                continue
            if c == '"':
                state = "DOUBLE"
                i += 1
                continue
            if c == "#":
                comment_at = i
                break
            i += 1

        if state == "SINGLE" and start_state == "CODE" and open_col is not None:
            if _AWK_NAME_RE.search(line[:open_col]):
                in_awk_single = True

        dropped = False
        if start_state == "CODE":
            if line.strip() == "":
                dropped = True
            elif comment_at is not None and line[:comment_at].strip() == "":
                dropped = True
        elif start_state == "SINGLE" and start_awk:
            stripped = line.strip()
            if stripped == "" or stripped.startswith("#"):
                dropped = True

        if idx < protect_until:
            dropped = False

        if not dropped:
            out.append(line)

    result = "\n".join(out)
    if text.endswith("\n") and not result.endswith("\n"):
        result += "\n"
    return result

# -- usage()-reads-its-own-source protection ---------------------------------

# scripts/jit-dry-run.sh and scripts/jit-match.sh each print their own header
# comment as --help text via `usage() { sed -n "N,Mp" "$0"; exit ...; }` --
# read off the ORIGINAL (uncompiled) source, because the line range is only
# meaningful against the file the author actually wrote and reviewed; once
# compiled the source line that used to hold `. "$SCRIPT_DIR/common.sh"` is
# always well after M in both files, so inlining never shifts this range.
_USAGE_SED_RE = re.compile(r"sed -n '\d+,(\d+)p' " + chr(34) + r"\$0" + chr(34))

# jit-init.sh's own usage() reads structurally instead of by a fixed line
# range ("Read structurally rather than as a line range: jit-dry-run.sh pins
# '2,31p', and a line added above that range truncates its --help with
# nothing to say" -- its own comment): `awk 'NR > 1 && /^#/ {print} NR > 1
# {exit}' "$0"` prints every comment line from line 2 until the first
# non-comment line. Comment-stripping that header is just as fragile to this
# shape as to a fixed sed range -- it removes exactly the lines usage() reads
# -- so it needs the same protection, computed by scanning for where the
# ORIGINAL file's own leading comment block actually ends.
_USAGE_STRUCTURAL_RE = re.compile(r"NR > 1 && /\^#/")


def _usage_structural_end_line(original_script_text: str) -> int:
    if not _USAGE_STRUCTURAL_RE.search(original_script_text):
        return 0
    lines = original_script_text.split("\n")
    end = 1  # line 1 (the shebang) is never part of what usage() prints
    for i in range(1, len(lines)):
        if lines[i].startswith("#"):
            end = i + 1  # 1-indexed
            continue
        break
    return end


def _usage_sed_end_line(original_script_text: str) -> int:
    m = _USAGE_SED_RE.search(original_script_text)
    if m:
        return int(m.group(1))
    return _usage_structural_end_line(original_script_text)


# -- driver -------------------------------------------------------------------

# Every script under scripts/ that needs compiling, and (for the ones that
# also run another scripts/ file as a subprocess) which calls to rewrite.
# jit-misses.sh is deliberately absent: it loads nothing else, so it ships
# byte-identical to main.
COMPILED_SCRIPTS = [
    "scripts/post-tool-hook.sh",
    "scripts/pre-path-hook.sh",
    "scripts/pre-tool-hook.sh",
    "scripts/pre-prompt-hook.sh",
    "scripts/stop-hook.sh",
    "scripts/session-start-hook.sh",
    "scripts/jit-stats.sh",
    "scripts/jit-doctor.sh",
    "scripts/jit-match.sh",
    "scripts/jit-dry-run.sh",
    "scripts/rebuild-tsv.sh",
    "scripts/jit-init.sh",
]


_SCRIPT_DIR_DEF = 'case "$0" in */*) SCRIPT_DIR="${0%/*}" ;; *) SCRIPT_DIR="." ;; esac'


def drop_dead_script_dir(script: str) -> str:
    """Remove the SCRIPT_DIR definition when nothing else in the compiled file reads it.

    It exists only to find common.sh; once the library is inlined it is dead code, and
    its `SCRIPT_DIR="."` fallback is read by the directory validator as the script
    naming a further file, `.`, which holds COMMAND_SCRIPT_NOT_FOLLOWED (#461). A file
    that still uses SCRIPT_DIR anywhere else keeps the line untouched.
    """
    lines = script.split("\n")
    users = [i for i, line in enumerate(lines) if "SCRIPT_DIR" in line]
    if len(users) == 1 and lines[users[0]].strip() == _SCRIPT_DIR_DEF:
        del lines[users[0]]
    return "\n".join(lines)


def compile_scripts(contents: dict[str, bytes]) -> dict[str, bytes]:
    """Mutate-and-return a {path: bytes} map: every script in COMPILED_SCRIPTS
    becomes self-contained and comment-stripped, LIBRARY_FILES are removed
    (nothing loads them by path any more), jit-misses.sh is untouched.
    Raises CompileError, never silently ships a script still pointing at a
    file the release tree does not carry."""
    needed = LIBRARY_FILES | set(COMPILED_SCRIPTS) | {"scripts/jit-misses.sh"}
    missing = [p for p in needed if p not in contents]
    if missing:
        raise CompileError(f"compile_scripts: expected file(s) missing from the tree: {missing}")

    def text(path: str) -> str:
        return contents[path].decode("utf-8")

    inlined_common_sh = build_inlined_common_sh(
        text("scripts/common.sh"), text("scripts/common-awk.sh"), text("scripts/host.sh"))

    common_dependents = [
        p for p in COMPILED_SCRIPTS
        if p not in ("scripts/jit-init.sh",)  # jit-init.sh never sources common.sh itself
    ]

    compiled: dict[str, str] = {}
    for path in common_dependents:
        compiled[path] = inline_common_sh(text(path), inlined_common_sh, path)

    # rebuild-tsv.sh must be fully self-contained (common.sh already inlined,
    # from the loop above) before its body can be wrapped as jit-init.sh's
    # subprocess-replacement function.
    jit_misses_body = text("scripts/jit-misses.sh")
    rebuild_tsv_compiled = compiled["scripts/rebuild-tsv.sh"]

    for path, calls in _SUBPROCESS_CALLS.items():
        current = compiled.get(path, text(path))
        for call_text, func_name, lib_path in calls:
            lib_body = jit_misses_body if lib_path == "scripts/jit-misses.sh" else rebuild_tsv_compiled
            current = inline_subprocess_call(current, call_text, func_name, lib_body, path)
        compiled[path] = current

    # jit-dry-run.sh drives three of the hooks directly, with a sample payload
    # on stdin, to answer "what would this rule do" (report_hook(), its own
    # name for the pattern) -- and jit-match.sh drives pre-prompt-hook.sh the
    # same way to cross-check a vocabulary match. Both calls are LEFT AS A
    # SUBPROCESS, deliberately, for two reasons rather than one:
    #
    # 1. Neither call site is on the directory's own COMMAND_SCRIPT_NOT_FOLLOWED
    #    path. That scan is breadth-first from a registered command (hooks.json,
    #    commands/*.md), and neither jit-dry-run.sh nor jit-match.sh is named by
    #    either -- confirmed by reading both at #461 -- so it never walks into
    #    this call at all.
    # 2. Inlining it anyway blows the OTHER budget the same checklist enforces:
    #    jit-dry-run.sh would have to carry pre-tool-hook.sh, pre-path-hook.sh
    #    AND pre-prompt-hook.sh's full compiled bodies (roughly 76+72+64 KB) on
    #    top of its own ~89 KB, past the 256 KiB per-file limit on its own --
    #    measured at 305104 bytes when this was tried. Solving a hold that does
    #    not apply here by tripping a different one that always does is not a
    #    fix.
    #
    # The target of each call is itself fully self-contained (every hook in
    # COMPILED_SCRIPTS above), so this is a real subprocess at a real,
    # always-present sibling path -- the same shape jit-init.sh/rebuild-tsv.sh
    # and session-start-hook.sh/jit-misses.sh used to be, not a dangling
    # reference to a file the release tree no longer carries.
    out = dict(contents)
    for path in COMPILED_SCRIPTS:
        protect_until = _usage_sed_end_line(text(path))
        out[path] = drop_dead_script_dir(
            strip_comments(compiled[path], protect_until)).encode("utf-8")
    for path in LIBRARY_FILES:
        del out[path]
    return out
