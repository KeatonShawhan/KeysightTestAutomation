#!/usr/bin/env bash
#
# cleanup_metrics.sh
#
# Deletes test run folders inside the metrics directory that are older than X days.
#
# Usage:
#   ./cleanup+_metrics.sh <days_old>
#

set -e

# Get script directory (test_scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

METRICS_DIR="${SCRIPT_DIR}/../metrics"

usage() {
  echo "Usage: $0 <days_old>"
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

DAYS_OLD="$1"

if ! [[ "$DAYS_OLD" =~ ^[0-9]+$ ]]; then
  echo "[ERROR] Days old must be a number."
  exit 1
fi

echo "[INFO] Cleaning up folders in $METRICS_DIR older than $DAYS_OLD days..."

find "$METRICS_DIR" -maxdepth 1 -type d -mtime "+$DAYS_OLD" ! -path "$METRICS_DIR" -exec rm -rf {} +

echo "[INFO] Cleanup complete."
