#!/bin/sh
set -eu

# Give the Cloud runner the same revision-specific macro approvals as Xcode.
security_dir="$HOME/Library/org.swift.swiftpm/security"
mkdir -p "$security_dir"
install -m 600 "$(dirname "$0")/macros.json" "$security_dir/macros.json"
