#!/usr/bin/env bash
# Runs the test suite. Extra arguments go to `swift test` (for example `--filter DecodeScheduler`).
#
# With only the Command Line Tools installed, SwiftPM does not find the Swift Testing
# framework they ship, so its location is passed explicitly. With full Xcode this is plain
# `swift test`.
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == *CommandLineTools* ]]; then
  frameworks="$developer_dir/Library/Developer/Frameworks"
  libraries="$developer_dir/Library/Developer/usr/lib"
  exec swift test \
    -Xswiftc -F -Xswiftc "$frameworks" \
    -Xlinker -F -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$libraries" \
    "$@"
fi
exec swift test "$@"
