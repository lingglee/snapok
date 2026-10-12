#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -O "$ROOT_DIR/Sources/Snapok/RedactionCandidates.swift" \
  "$ROOT_DIR/Sources/Snapok/ImageTranslation.swift" \
  "$ROOT_DIR/Sources/Snapok/Localization.swift" \
  "$ROOT_DIR/Tests/SnapokTests/RedactionCandidatesTests.swift" -o "$TEST_DIR/redaction-review-tests"
"$TEST_DIR/redaction-review-tests" "$@"
