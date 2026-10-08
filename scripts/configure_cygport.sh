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
# Also makes autoconf fail on an unexpanded third-party macro (AX_* from
# autoconf-archive, PKG_* from pkgconf's pkg.m4) instead of silently
# succeeding. autoconf only forbids its own prefixes (^_?A[CHUMST]_,
# ^_?m4_, ^_?AS_, ...) out of the box, so when the macro's .m4 isn't
# installed, the bare name is just copied into configure as text: with
# arguments that's a configure-time syntax error at least, but without
# (e.g. AX_CODE_COVERAGE) it's a `command not found` that configure
# shrugs off with rc=0 -- or nothing at all inside an untaken AS_IF -- and
# the package silently comes out different. xezat used to scan
# configure.ac for this and add autoconf-archive to BUILD_REQUIRES itself
# (removed in fd00/xezat 21c35f6); now this clean build environment
# catches it instead, and a human adds the BUILD_REQUIRES by hand
# (doc/spec.md 4.3.1). autoconf reads acsite.m4 from its include path
# (autom4te.cfg's Autoconf-without-aclocal-m4 language), so an acsite.m4
# with m4_pattern_forbid in a directory of its own, prepended via
# `autoconf -B`, does it without touching the upstream configure.ac.
# autoreconf runs whatever $AUTOCONF says (as does automake's own
# --trace call), and cygport's cygautoreconf only exports AUTOCONF, never
# overrides it (unless NO_AUTOCONF is set, which skips autoconf -- and
# this check -- entirely). Cygwin's /usr/bin/autoconf is Gentoo's
# ac-wrapper, which passes -B through to autoconf-2.7x as-is
# (`exec "${binary}" "$@"`). Macros a package bundles itself (m4/ax_*.m4
# via AC_CONFIG_MACRO_DIRS) are defined by then, so they still expand
# fine. The patterns match the whole upper-case token, as libtool's and
# pkg.m4's own do, not just its prefix, to keep false positives on shell
# variables down; PKG_CONFIG, PKG_CONFIG_PATH etc. are allowed the same
# way pkg.m4 allows them, since a configure.ac can use those in plain
# shell code without pkg.m4 at all (confirmed locally: PKG_CONFIG_PATH
# alone trips the forbid otherwise).
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

mkdir -p "$HOME/.cygport-autoconf"
cat > "$HOME/.cygport-autoconf/acsite.m4" <<'EOF'
dnl Make autoconf fail on unexpanded third-party macros instead of
dnl silently copying them into configure (see dorgann doc/spec.md 4.3.1).
m4_pattern_forbid([^_?AX_[A-Z0-9_]+$])
m4_pattern_forbid([^_?PKG_[A-Z_]+$])
dnl Same allow-list pkg.m4 itself has, for configure.ac files that use
dnl these variables in plain shell code without pkg.m4.
m4_pattern_allow([^PKG_CONFIG(_(PATH|LIBDIR|SYSROOT_DIR|ALLOW_SYSTEM_(CFLAGS|LIBS)))?$])
EOF

cat > "$HOME/.cygportrc" <<'EOF'
PATH=/usr/bin:/usr/local/bin:$(cygpath "${SYSTEMROOT}")/system32
_cygportrc_pwd="$PWD"
source /etc/profile >&2
cd "$_cygportrc_pwd"
unset _cygportrc_pwd
DISTDIR=$HOME/distfiles
export AUTOCONF="autoconf -B $HOME/.cygport-autoconf"

make()
{
	/usr/bin/make V=1 VERBOSE=1 $*
}
ninja()
{
	/usr/bin/ninja -v $*
}
EOF
