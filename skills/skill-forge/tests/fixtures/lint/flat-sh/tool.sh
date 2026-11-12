#!/usr/bin/env bash
# flat-sh: roll a service's config forward. A fixture's violations: no dry run,
# no header, no masker.
set -eu
if [ "${1:-}" = "--help" ]; then
  echo "usage: tool.sh SERVICE"
  exit 0
fi
SERVICE="$1"
echo "rolling $SERVICE"
kubectl -n apps apply -f "configs/$SERVICE.yaml"
