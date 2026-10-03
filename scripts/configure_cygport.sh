#!/usr/bin/env bash
# Configures cygport's DISTDIR so `cygport fetch` (called by `xezat prep`)
# saves downloaded source tarballs there instead of its default location:
# whatever the current working directory happens to be when fetch runs
# (see cygport's own lib/src_fetch.cygpart -- it only moves the downloaded
# file into DISTDIR if DISTDIR is *set*; otherwise the file is simply left
# where it landed). Since this workflow cds into the package directory
# itself before invoking cygport, an unset DISTDIR meant every downloaded
# tarball ended up sitting right next to the tracked .cygport file --
# indistinguishable from a real source-controlled file to `git add -A`,
# and multi-megabyte binary blobs are exactly what a git history should
# never accumulate.
#
# Also wraps make/ninja to force verbose build output (V=1 VERBOSE=1 /
# -v), matching the maintainer's own local .cygportrc -- makes a real
# compile failure's log actually show the failing command instead of
# just "make: *** [Makefile:123: foo.o] Error 1".
#
# Also resets PATH for everything cygport runs, the same way Cygwin's
# official CI (cygwin/scallywag) does: /usr/bin, /usr/local/bin and
# Windows' system32 only (its .github/workflows/build.yml), then
# /etc/profile re-read so /etc/profile.d/ additions from installed
# packages (e.g. lapack's /usr/lib/lapack) still apply (its build.sh).
# Each workflow step's `bash --` is a non-login Cygwin shell, so
# /etc/profile never runs on its own and the runner's whole Windows PATH
# leaks through as-is -- confirmed by a real run where CMake's
# FindDoxygen picked up Strawberry Perl's bundled
# /cygdrive/c/Strawberry/c/bin/doxygen.exe (without `dot`) instead of
# finding no doxygen at all, and failed configure. Only cygport's own
# environment is narrowed, not the workflow's: xezat itself still needs
# the gem bindir that xezat_cache_info.sh appends to GITHUB_PATH, but
# nothing cygport invokes does.
#
# /etc/profile cds to $HOME, so the working directory is restored after
# it (as scallywag's build.sh does too), and its stdout goes to stderr:
# cygport_depends.sh evals `cygport ... vars` output, which anything
# profile.d prints would otherwise corrupt.
#
# cygport reads this from (in order) $HOME/.config/cygport.conf,
# $HOME/.cygport/cygport.conf, $HOME/.cygport.conf, or $HOME/.cygportrc --
# see cygport's own data/cygport.conf for the full list. It's sourced as
# a plain bash script, so the function overrides below take effect the
# same way they would in an interactive shell's .bashrc.
#
# Usage: configure_cygport.sh (no arguments; run once, before any cygport
# invocation)

set -euo pipefail

cat > "$HOME/.cygportrc" <<'EOF'
PATH=/usr/bin:/usr/local/bin:$(cygpath "${SYSTEMROOT}")/system32
_cygportrc_pwd="$PWD"
source /etc/profile >&2
cd "$_cygportrc_pwd"
unset _cygportrc_pwd
DISTDIR=$HOME/distfiles

make()
{
	/usr/bin/make V=1 VERBOSE=1 $*
}
ninja()
{
	/usr/bin/ninja -v $*
}
EOF
