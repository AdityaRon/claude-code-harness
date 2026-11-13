#!/usr/bin/env bash
# Sourced by the suites in tests/: the counts each one reports on its
# "--- Results: N passed, M failed ---" line, which doctor.sh reads.
pass() { echo "  OK: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1  $2"; FAIL=$((FAIL+1)); }
