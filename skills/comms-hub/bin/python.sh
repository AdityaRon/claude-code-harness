#!/usr/bin/env bash
# Prints the first interpreter on PATH that can run comms-hub: Python 3.10 or
# newer with a TOML reader (tomllib from 3.11, the tomli package on 3.10).
# macOS ships python3 3.9, so a bare `python3` is not enough.
for c in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
  p=$(command -v "$c" 2>/dev/null) || continue
  if "$p" -c 'import sys, importlib.util as u
sys.exit(0 if sys.version_info >= (3, 10) and (u.find_spec("tomllib") or u.find_spec("tomli")) else 1)' 2>/dev/null; then
    echo "$p"
    exit 0
  fi
done
echo "no Python 3.10+ with tomllib or tomli on PATH: brew install python@3.12 (macOS); apt-get install python3-tomli or dnf install python3-tomli on a 3.10 Linux, or a newer python3 package" >&2
exit 1
