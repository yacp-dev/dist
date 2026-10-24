#!/usr/bin/env bash
# Re-embeds the package's README into $D after `xezat bump` has
# rewritten it, so the next `cygport package` ships the updated one.
#
# cygport's `install` step already embedded it once (postinst's
# __prepdoc: `newins ${C}/README ${PN}.README` into
# /usr/share/doc/Cygwin), but from the pre-bump copy xezat prep put in
# $C. Running `cygport postinst` again to refresh it would also re-run
# the rest of __prepdoc, and that isn't idempotent: dodoc installs only
# the first of FOO, FOO.md, FOO.rst, FOO.txt it finds, skipping any
# already in $D -- so a second pass, with README already there, adds
# README.md too (ffmpegthumbnailer 2.3.1). The package then ships a file
# that the README's own file list, written by xezat bump from the first
# pass's .lst, doesn't mention. Copying just this one file keeps $D what
# a single cygport run would have made.
#
# None embedded means cygport left it out: RESTRICT=postinst_doc or
# python-wheel's per-package docs (_CYGPORT_INTERNAL_multi_doc_, where
# cygport never embeds one), which this doesn't second-guess, or no
# $C/README at install time -- a new package's first build (doc/spec.md
# 4.8), whose README only exists once xezat bump has written it. That
# one is installed here, since xezat bump lists
# usr/share/doc/Cygwin/$PN.README among the package's files regardless.
#
# Usage (paths relative to the package directory, e.g. yacp/googletest):
#   embed_readme.sh --dir yacp/googletest --file googletest-1.18.0-1bl1.cygport

set -euo pipefail

dir=""
cygport_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --file) cygport_file="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$dir" ]] || { echo "--dir is required" >&2; exit 1; }
[[ -n "$cygport_file" ]] || { echo "--file is required" >&2; exit 1; }

cd "$dir"
[[ -f "$cygport_file" ]] || { echo "No such file: $dir/$cygport_file" >&2; exit 1; }

# Same `cygport <file> vars <NAME>` mechanism as the diagnose_*.sh.
vars_decl="$(cygport "$cygport_file" vars C D PN RESTRICT _CYGPORT_INTERNAL_multi_doc_)"
C="" D="" PN="" RESTRICT="" _CYGPORT_INTERNAL_multi_doc_=""
eval "$vars_decl"
[[ -n "$C" && -n "$D" && -n "$PN" ]] || { echo "embed_readme.sh: 'cygport $cygport_file vars C D PN ...' didn't give C, D and PN" >&2; exit 1; }

dest="$D/usr/share/doc/Cygwin/$PN.README"
if [[ ! -f "$dest" ]] && [[ " $RESTRICT " == *" postinst_doc "* || -n "$_CYGPORT_INTERNAL_multi_doc_" ]]; then
  echo "embed_readme.sh: no $dest from cygport install (RESTRICT=postinst_doc or per-package docs) -- nothing to replace"
  exit 0
fi
[[ -f "$C/README" ]] || { echo "embed_readme.sh: $C/README isn't there to embed" >&2; exit 1; }

install -D -m0644 "$C/README" "$dest"
echo "embed_readme.sh: $C/README -> $dest"
