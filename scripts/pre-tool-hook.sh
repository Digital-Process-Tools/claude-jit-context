#!/bin/bash
# claude-jit-context — PreToolUse hook
# Single awk process: parses JSON, scans tool + vocab TSVs, outputs JSON.
# Bash wrapper only handles timing (2 perl calls) and log writing.

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/common.sh"
T_START=$(_ms)

SHOWN_FILE="/tmp/claude-vocab-shown-$PPID.txt"
[ -f "$SHOWN_FILE" ] || : > "$SHOWN_FILE"
LOG_TMP="/tmp/claude-hook-log-$$.tmp"

cat | awk \
  -v tools_tsv="$JIT_BASE/tools/00-manual/00-index.tsv" \
  -v tools_dir="$JIT_BASE/tools/00-manual" \
  -v vocab_base="$JIT_BASE/vocabulary" \
  -v shown_file="$SHOWN_FILE" \
  -v home="$HOME" \
  -v project="${CLAUDE_PROJECT_DIR:-.}" \
  -v log_tmp="$LOG_TMP" \
'
{ input = input $0 }
END {
  # --- Parse JSON: split on quotes, extract key-value pairs ---
  n = split(input, f, "\"")
  for (i = 2; i <= n; i += 2) {
    v = f[i+2]
    k = f[i]
    if (k == "tool_name") tool_name = v
    else if (k == "command") command = v
    else if (k == "skill") f_skill = v
    else if (k == "file_path") f_file_path = v
    else if (k == "pattern") f_pattern = v
    else if (k == "description") f_desc = v
    else if (k == "prompt") f_prompt = v
    else if (k == "query") f_query = v
  }

  # Fallback chain for tool matching
  full_command = command
  if (full_command == "") full_command = f_skill
  if (full_command == "") full_command = f_file_path
  if (full_command == "") full_command = f_pattern

  # Strip to command words (before ; & | quotes flags)
  cmd = full_command
  gsub(/[;&|].*/, "", cmd)
  gsub(/".*/, "", cmd)
  gsub(/ --.*/, "", cmd)

  if (tool_name == "" || cmd == "") { print "{}"; exit }

  matched = ""
  blocked = ""
  log_matches = ""
  sep = ""

  # --- Load shown file into set ---
  while ((getline sline < shown_file) > 0) shown[sline] = 1
  close(shown_file)

  # --- Tool rules matching ---
  while ((getline tline < tools_tsv) > 0) {
    split(tline, tf, "\t")
    r_tool = tf[1]; r_match = tf[2]; r_file = tf[3]
    r_modes = tf[4]; r_require = tf[5]; r_forbid = tf[6]

    # tool may name several tools, pipe-separated: `tool: Edit|Write|Read`.
    # Exact-match each alternative — never substring, or `Read` would match `ReadFile`.
    tool_hit = 0
    nt = split(r_tool, talts, "|")
    for (ti = 1; ti <= nt; ti++) if (talts[ti] == tool_name) tool_hit = 1
    if (!tool_hit) continue
    if (substr(r_match, 1, 1) == "~") {
      # Regex rules match the WHOLE command, not the truncated first segment:
      # `cmd` is stripped at the first ; & | so `cd X && git push` was only ever
      # tested as `cd X`, and every rule after a chain operator silently never
      # fired. A rule that reads as enforced and is not is worse than no rule.
      if (match(tolower(full_command), substr(r_match, 2)) == 0) continue
    } else {
      if (index(tolower(cmd), tolower(r_match)) == 0) continue
    }

    # "once" mode
    if (index(r_modes, "once") > 0) {
      key = "rule:" r_file
      if (key in shown) continue
      shown[key] = 1
      print key >> shown_file
    }

    # Read rule .md
    content = ""
    rpath = tools_dir "/" r_file
    while ((getline rl < rpath) > 0) content = content (content == "" ? "" : "\n") rl
    close(rpath)

    # Check require
    if (r_require != "") {
      nr = split(r_require, reqs, "|")
      for (ri = 1; ri <= nr; ri++) {
        if (index(tolower(full_command), tolower(reqs[ri])) == 0) {
          blocked = "BLOCKED: Missing required: " reqs[ri] ". " content
          log_matches = log_matches sep "tool:" r_file "(BLOCKED:" reqs[ri] ")"
          sep = ", "; break
        }
      }
      if (blocked != "") break
    }

    # Check forbid
    if (r_forbid != "" && blocked == "") {
      nfb = split(r_forbid, forbs, "|")
      for (fi = 1; fi <= nfb; fi++) {
        if (index(tolower(full_command), tolower(forbs[fi])) > 0) {
          blocked = "BLOCKED: Forbidden: " forbs[fi] ". " content
          log_matches = log_matches sep "tool:" r_file "(BLOCKED:" forbs[fi] ")"
          sep = ", "; break
        }
      }
      if (blocked != "") break
    }

    if (content != "" && blocked == "") {
      header = "# JIT Context: " r_file " (matched: " r_match ")"
      log_matches = log_matches sep "tool:" r_file "(" r_match ")"
      sep = ", "

      if (index(r_modes, "block") > 0) { blocked = header "\n" content; break }

      if (matched != "") matched = matched "\n---\n" header "\n" content
      else matched = header "\n" content
    }
  }
  close(tools_tsv)

  # --- Vocabulary matching ---
  # Bind vocab to WHERE the tool acts (target path), not WHAT the payload says.
  # Matching command verbs / descriptions / patterns fired unrelated module
  # entries on incidental words ("feedback" in a comment, "checkout" in a git
  # verb). Path-only: an Edit/Read file_path, plus path-like tokens (those
  # containing "/") lifted out of a Bash/supertool command so
  # `./supertool edit:..src/Billing/..` still binds to Billing. No path -> no vocab
  # here; the prompt hook still injects on what the user is actually discussing.
  cmd_paths = ""
  np = split(command, ptoks, / /)
  for (pi = 1; pi <= np; pi++) {
    if (index(ptoks[pi], "/") > 0) cmd_paths = cmd_paths " " ptoks[pi]
  }
  tt = f_file_path " " cmd_paths
  gsub(home "/", "", tt)
  gsub(project "/", "", tt)

  # Word-boundary match prep:
  # 1. Split CamelCase: "SiProjectModule" -> "Si Project Module"
  cc = ""
  for (i = 1; i <= length(tt); i++) {
    c = substr(tt, i, 1)
    p = (i > 1) ? substr(tt, i-1, 1) : ""
    if (c ~ /[A-Z]/ && p ~ /[a-z0-9]/) cc = cc " " c
    else cc = cc c
  }
  tt = tolower(cc)
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", tt)
  # 2. Pad + strip non-alnum (keep hyphens) for space-bounded kw lookup
  padded = " " tt " "
  gsub(/[^a-z0-9 -]/, " ", padded)
  gsub(/  +/, " ", padded)

  if (tt != "") {
    split("00-manual 10-auto 20-grouped 30-crosscutting", layers, " ")
    for (li = 1; li <= 4; li++) {
      layer = layers[li]
      lookup = vocab_base "/" layer "/00-index.tsv"

      # Single pass: match keywords, collect files + matched keywords
      delete vmatch
      while ((getline vl < lookup) > 0) {
        split(vl, vf, "\t")
        kw = vf[1]; vfile = vf[2]
        if (!(vfile in shown) && index(padded, " " kw " ") > 0) {
          if (vfile in vmatch) vmatch[vfile] = vmatch[vfile] "|" kw
          else vmatch[vfile] = kw
        }
      }
      close(lookup)

      for (vfile in vmatch) {
        shown[vfile] = 1
        print vfile >> shown_file

        vc = ""
        vpath = vocab_base "/" layer "/" vfile
        while ((getline vcl < vpath) > 0) vc = vc (vc == "" ? "" : "\n") vcl
        close(vpath)

        if (vc != "") {
          vh = "# Vocabulary: " vfile " (matched: " vmatch[vfile] ")"
          if (layer ~ /00-manual/) vh = vh "\\n[vocab-upkeep] Learned something new here, or found this entry wrong? Edit it now — hand-written entries live in 00-manual/."
          log_matches = log_matches sep layer ":" vfile "(" vmatch[vfile] ")"
          sep = ", "
          if (matched != "") matched = matched "\n---\n" vh "\n" vc
          else matched = vh "\n" vc
        }
      }
    }
  }
  close(shown_file)

  # --- Write log info to temp file (bash reads it for timing) ---
  sc = 0; for (s in shown) sc++
  tt_short = substr(tt, 1, 120)
  if (log_matches == "") log_matches = "(none)"
  printf "%s\t%s\t%d\t%s\n", tool_name, log_matches, sc, tt_short > log_tmp
  close(log_tmp)

  # --- Output JSON ---
  if (blocked != "") {
    gsub(/\\/, "\\\\", blocked); gsub(/"/, "\\\"", blocked)
    gsub(/\t/, "\\t", blocked); gsub(/\n/, "\\n", blocked)
    printf "{\"decision\":\"block\",\"reason\":\"%s\"}", blocked
  } else if (matched != "") {
    gsub(/\\/, "\\\\", matched); gsub(/"/, "\\\"", matched)
    gsub(/\t/, "\\t", matched); gsub(/\n/, "\\n", matched)
    printf "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"%s\"}}", matched
  } else {
    print "{}"
  }
}
'

# --- Timing + log ---
T_END=$(_ms)
TOTAL=$((T_END - T_START))

if [ -f "$LOG_TMP" ]; then
  IFS=$'\t' read -r AWK_TOOL AWK_MATCHES AWK_SHOWN AWK_TEXT < "$LOG_TMP"
  _log_hook "pre-tool ($AWK_TOOL)" "$TOTAL" "$AWK_MATCHES [shown:$AWK_SHOWN] << $AWK_TEXT"
  rm -f "$LOG_TMP"
fi
