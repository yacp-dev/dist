#!/usr/bin/env bash
# Installs xezat from the HEAD of its GitHub repository (fd00/xezat)
# instead of its latest RubyGems.org release, so this workflow always
# builds against the newest xezat source, including changes not yet
# published as a gem. The install isn't cached across runs: xezat's
# dependencies are all pure Ruby, so caching saves little, and a cache
# would keep them at old versions that still satisfy xezat's `>=`
# constraints instead of picking up their fixes.
#
# Clones into a RELATIVE path under the current directory rather than an
# absolute /tmp/... one -- confirmed by a real run's diagnostics
# (2026-08-15) that this step's `git` is native Git for Windows (`git
# version 2.55.0.windows.3`), not a Cygwin-native binary, even though the
# script itself runs under Cygwin bash. Git for Windows resolves a
# leading `/tmp/...` through its own MSYS2 path mapping, which points
# somewhere other than Cygwin's own /tmp (what `cd` and `mktemp -d` here
# resolve it to) -- so `git clone` and this script's own `cd` ended up
# operating on two different real directories: the clone silently
# "succeeded" into one location while `cd` landed in an empty one, and
# `gem build` then failed to find xezat.gemspec. A relative path sidesteps
# this entirely, since both tools resolve it against the same OS-level
# current directory regardless of which one's path-translation scheme
# they use.
#
# Usage: xezat_install.sh (no arguments)

set -euo pipefail

repo_dir="xezat-src-$$"
trap 'rm -rf "$repo_dir"' EXIT

git clone --depth 1 https://github.com/fd00/xezat.git "$repo_dir"

# The clone lands owner-only (rwx------), presumably because whichever
# git actually wrote the files (see the /tmp note above -- it's not
# always the same binary run to run) doesn't apply a world-readable mode
# under Cygwin. `gem build` below still succeeds either way, but warns
# "<file> is not world-readable" for every single file in the repo
# without this -- gem authors are expected to ship world-readable files
# since other users may `gem install` the built package.
chmod -R a+rX "$repo_dir"

# Defensive check, kept from diagnosing the /tmp mismatch above -- cheap
# insurance against whatever the next surprise turns out to be.
gemspec="$repo_dir/xezat.gemspec"
if [[ ! -f "$gemspec" ]]; then
  echo "xezat_install.sh: '$gemspec' missing after clone -- dumping '$repo_dir' for diagnosis:" >&2
  ls -la "$repo_dir" >&2
  git --version >&2
  git -C "$repo_dir" status >&2 || echo "xezat_install.sh: git status failed too" >&2
  git -C "$repo_dir" log -1 --oneline >&2 || echo "xezat_install.sh: git log failed too" >&2
  exit 1
fi

(
  cd "$repo_dir"
  gem build xezat.gemspec
  gem install --no-document ./xezat-*.gem
)

# Makes the gems' executables (xezat itself included) runnable from later
# steps. Neither Gem.user_dir + "/bin" nor `gem environment`'s "EXECUTABLE
# DIRECTORY" (/usr/bin) is where they land -- Cygwin's system-wide gem
# config forces every install to add `--user-install --bindir $HOME/bin`
# (visible as `gem environment`'s GEM CONFIGURATION entry
# `"gem" => "--user-install --bindir /home/runneradmin/bin"`), confirmed by
# the actual "gem install" warning ("You don't have
# /home/runneradmin/bin in your PATH") in a real run. Each workflow step
# is its own bash invocation (started fresh via `bash -- script.sh`, not a
# login/interactive shell), so nothing sources a profile that would
# normally add this to PATH -- without it, e.g. `xezat prep` fails with
# "xezat: command not found" even though `gem install xezat` just
# succeeded. GITHUB_PATH takes a Windows-style path.
gem_bindir="$(cygpath -w "$(ruby -e 'print File.join(Dir.home, "bin")')")"
echo "gem_bindir=$gem_bindir"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$gem_bindir" >> "$GITHUB_PATH"
fi
