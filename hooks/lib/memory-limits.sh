#!/usr/bin/env bash
# The memory index's numbers, one copy: memory-lint.sh, session-start.sh,
# bin/memory-index.sh and bin/memory-verify.sh source this. It is not one of
# lib.sh's parts, so the guards never load it. The _CHARS env names are
# historical; the values are bytes, as `wc -c` counts them.
# shellcheck disable=SC2034  # read by the files that source this
MEMORY_MAX_LINES="${MEMORY_INDEX_MAX_LINES:-200}"
MEMORY_MAX_BYTES="${MEMORY_INDEX_MAX_CHARS:-25000}"
MEMORY_PRESSURE_LINES="${MEMORY_INDEX_PRESSURE_LINES:-180}"
MEMORY_PRESSURE_BYTES="${MEMORY_INDEX_PRESSURE_CHARS:-20000}"
# Per index line, in characters: bytes less UTF-8 continuation bytes.
MEMORY_LINE_MAX="${MEMORY_INDEX_LINE_MAX:-110}"

# memory_pressure LINES BYTES: true at or past either pressure threshold.
memory_pressure() { [ "$1" -ge "$MEMORY_PRESSURE_LINES" ] || [ "$2" -ge "$MEMORY_PRESSURE_BYTES" ]; }
