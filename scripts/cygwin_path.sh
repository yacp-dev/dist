#!/usr/bin/env bash
# Sourced, not run: restrict_path_to_cygwin drops the Windows directories
# (anything under /cygdrive/) from PATH, keeping Cygwin's own entries in
# their order.
#
# The steps that run cygport are plain `bash -- scripts/...` calls, not
# login shells, so they inherit the runner's whole Windows PATH behind
# Cygwin's /usr/bin. Whatever Cygwin itself has wins, but a tool the
# recipe's BUILD_REQUIRES leave out is then found under C:\Windows or the
# runner's own toolchains instead of failing as missing: libavif 1.4.2's
# test_cmd_icc_profile and test_cmd_transform ran System32's convert.exe
# (the FAT-to-NTFS converter, "Invalid drive specification.") where they
# meant ImageMagick's. System32 alone also has find, sort, timeout, more,
# expand, hostname, whoami, tar, curl, ssh and a WSL bash.exe; the runner
# image adds Windows builds of python, perl, cmake and more. Without them,
# a missing tool fails as missing (or a test skips itself, which
# Audit recipe's Check section reports), and the fix -- a BUILD_REQUIRES
# entry -- is plain from the log.
#
# Usage:
#   source "$(dirname "$0")/cygwin_path.sh"
#   restrict_path_to_cygwin

restrict_path_to_cygwin() {
  local IFS=:
  local entries entry kept=() dropped=0
  read -r -a entries <<<"$PATH"
  for entry in "${entries[@]}"; do
    case "$entry" in
      "") ;;
      /cygdrive/*) dropped=$((dropped + 1)) ;;
      *) kept+=("$entry") ;;
    esac
  done
  case ":${kept[*]}:" in
    *:/usr/bin:*) ;;
    *) kept+=(/usr/local/bin /usr/bin) ;;
  esac
  PATH="${kept[*]}"
  export PATH
  if (( dropped > 0 )); then
    echo "PATH: left out $dropped Windows director$( ((dropped == 1)) && echo y || echo ies) (/cygdrive/...), so a tool missing from BUILD_REQUIRES fails as missing" >&2
  fi
}
