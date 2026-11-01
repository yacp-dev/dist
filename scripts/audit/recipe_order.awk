# Where a .cygport declares things, for audit/recipe_vars.sh. Prints one
# line per thing out of place, for a warning:
#
#   - PATCH_URI goes on the line right after SRC_URI, no blank line between
#   - each <sub>_REQUIRES goes after the last *_SUMMARY (not BUILD_REQUIRES)
#   - one blank line between DESCRIPTION and LICENSE
#
# Only assignments at column 0 count: an indented one is in a function or
# an `if`, where its position says nothing. Values can span lines, so the
# end of each is found by following its quotes.

# The quote still open after scanning s, given the one open before it.
function scan(s, q,    i, c) {
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q == "\"") {
      if (c == "\\") i++
      else if (c == "\"") q = ""
    } else if (q == "'") {
      if (c == "'") q = ""
    } else if (c == "\\") {
      i++
    } else if (c == "\"" || c == "'") {
      q = c
    } else if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) {
      break
    }
  }
  return q
}

{
  if (open != "") {
    open = scan($0, open)
    if (open == "") end[cur] = NR
    next
  }
  if (!match($0, /^[A-Za-z_][A-Za-z0-9_]*\+?=/)) next
  cur = substr($0, 1, RLENGTH - 1)
  sub(/\+$/, "", cur)
  open = scan(substr($0, RLENGTH + 1), "")
  if (!(cur in first)) first[cur] = NR
  end[cur] = NR
  if (cur ~ /_SUMMARY$/) last_summary = NR
  if (cur ~ /_REQUIRES$/ && cur != "BUILD_REQUIRES" && !(cur in req)) {
    req[cur] = NR
    reqs[++nreqs] = cur
  }
}

END {
  if (("PATCH_URI" in first) && ("SRC_URI" in first) && first["PATCH_URI"] != end["SRC_URI"] + 1)
    printf "PATCH_URI (line %d) belongs on the line right after SRC_URI (ends at line %d), no blank line between\n", first["PATCH_URI"], end["SRC_URI"]
  for (i = 1; i <= nreqs; i++)
    if (req[reqs[i]] < last_summary)
      printf "%s (line %d) belongs after the last *_SUMMARY (line %d)\n", reqs[i], req[reqs[i]], last_summary
  if (("LICENSE" in first) && ("DESCRIPTION" in first) && first["LICENSE"] == end["DESCRIPTION"] + 1)
    printf "LICENSE (line %d) needs one blank line between it and DESCRIPTION\n", first["LICENSE"]
}
