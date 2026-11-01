#!/usr/bin/env bash
# Points RUBYOPT at scripts/bashvar_diagnostic_patch.rb for the rest of
# this job, via GITHUB_ENV rather than just this step's own `env:` --
# every later `xezat` invocation (bump and port both call
# Xezat#variables, which is what crashes -- see that file's own header
# for the full story) needs to pick up the workaround, not just the very
# next one.
#
# Usage: configure_bashvar_diagnostic.sh (no arguments; run from the
# dorgann checkout root, i.e. build-package.yml's default working
# directory, same as every other scripts/*.sh reference in that file)

set -euo pipefail

patch_file="$(pwd)/scripts/bashvar_diagnostic_patch.rb"
[[ -f "$patch_file" ]] || { echo "No such file: $patch_file" >&2; exit 1; }
[[ -n "${GITHUB_ENV:-}" ]] || { echo "GITHUB_ENV must be set" >&2; exit 1; }

echo "RUBYOPT=-r$patch_file" >> "$GITHUB_ENV"
