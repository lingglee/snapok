#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
python3 -m compileall -q linux
PYTHONPATH=linux python3 -m unittest discover -s linux/tests -v
