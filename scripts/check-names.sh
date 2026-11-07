#!/usr/bin/env bash
# Fails if anything that gets published names the application this project is inspired by.
#
#   scripts/check-names.sh                  files in the work tree (tracked, and new ones not ignored)
#   scripts/check-names.sh --commits RANGE  commit messages AND changes in a git range, e.g. origin/main..HEAD
#   scripts/check-names.sh --stdin          text on standard input, e.g. a pull request's title and body
#
# Project rule: describe features directly ("a fast, keyboard-driven image viewer"); never name
# the product this one is modelled on, in code, comments, tests, docs, commit messages, pull
# requests or issues.
#
# The match is case-insensitive and allows a space, hyphen or underscore inside the name. It is
# a plain substring match: a person whose given name contains it will trip it, and the fix is to
# write their name another way. Binary files are searched too (git reports "Binary file ...
# matches").
#
# The term is assembled from pieces so that this file does not itself contain it.
set -euo pipefail
cd "$(dirname "$0")/.."

pattern="$(printf '%s%s%s' 'ir' '[ _-]\{0,1\}' 'fan')"
found=0

report() {
  echo "error: $1 names the application this project is inspired by. Describe the feature instead." >&2
  found=1
}

usage() { echo "usage: $0 [--commits RANGE | --stdin]" >&2; exit 64; }

case "${1:-files}" in
  files)
    # File names, then contents.
    if git ls-files --cached --others --exclude-standard | grep -i -e "$pattern" >&2; then
      report "a file name"
    fi
    if git grep -nHi --untracked -e "$pattern" >&2; then
      report "a file"
    fi
    ;;
  --commits)
    range="${2:-}"
    [[ -n "$range" ]] || usage
    # Fetch the history first, on its own line: a bad range must fail the script, not skip the check.
    messages="$(git log --format='%H %B' "$range")"
    changes="$(git log -p --format= "$range")"
    if grep -i -e "$pattern" <<<"$messages" >&2; then
      report "a commit message"
    fi
    # A commit that adds the name and a later one that removes it still published it.
    if grep -i -e "$pattern" <<<"$changes" >&2; then
      report "a commit's changes"
    fi
    ;;
  --stdin)
    if grep -i -e "$pattern" >&2; then
      report "the text"
    fi
    ;;
  *)
    usage
    ;;
esac

exit "$found"
