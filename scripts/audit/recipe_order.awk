# Where a .cygport declares things, for audit/recipe_vars.sh. Prints one
# line per thing out of place, for a warning:
#
#   - PATCH_URI goes with the source at the top, no blank line between: on
#     the line right after SRC_URI, or, when SRC_URI is only added to after
#     an inherit (git.cygclass and the like set it, so `SRC_URI+=` has to
#     come after them), right after the last of the source variables before
#     the first inherit (GIT_REV, GIT_TAG, ...; HOMEPAGE when there are none)
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

# The assignment to cur ends at line n.
function ended(n) {
  end[cur] = n
  if (cur == "SRC_URI" && kind == "top" && !src_end) src_end = n
  if (kind == "header") { hdr_end = n; hdr_var = cur }
}

{
  if (open != "") {
    open = scan($0, open)
    if (open == "") ended(NR)
    next
  }
  if ($0 ~ /^inherit[ \t]/) inherited = 1
  if (!match($0, /^[A-Za-z_][A-Za-z0-9_]*\+?=/)) next
  cur = substr($0, 1, RLENGTH - 1)
  appended = sub(/\+$/, "", cur)
  kind = ""
  if (cur == "SRC_URI" && !(appended && inherited)) kind = "top"
  else if (!inherited && cur ~ /^(HOMEPAGE|(GIT|SVN|HG|BZR|CVS|FOSSIL|MTN)_[A-Z_]+)$/) kind = "header"
  open = scan(substr($0, RLENGTH + 1), "")
  if (!(cur in first)) first[cur] = NR
  if (open == "") ended(NR)
  if (cur ~ /_SUMMARY$/) last_summary = NR
  if (cur ~ /_REQUIRES$/ && cur != "BUILD_REQUIRES" && !(cur in req)) {
    req[cur] = NR
    reqs[++nreqs] = cur
  }
}

END {
  if ("PATCH_URI" in first) {
    if (src_end) { after = "SRC_URI"; at = src_end }
    else if (hdr_end) { after = hdr_var; at = hdr_end }
    else at = 0
    if (at && first["PATCH_URI"] != at + 1)
      printf "PATCH_URI (line %d) belongs on the line right after %s (ends at line %d), no blank line between\n", first["PATCH_URI"], after, at
  }
  for (i = 1; i <= nreqs; i++)
    if (req[reqs[i]] < last_summary)
      printf "%s (line %d) belongs after the last *_SUMMARY (line %d)\n", reqs[i], req[reqs[i]], last_summary
  if (("LICENSE" in first) && ("DESCRIPTION" in first) && first["LICENSE"] == end["DESCRIPTION"] + 1)
    printf "LICENSE (line %d) needs one blank line between it and DESCRIPTION\n", first["LICENSE"]
}
