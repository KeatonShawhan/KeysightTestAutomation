#!/usr/bin/env bash

# Simulates a network outage from the perspective of test runners by stopping them mid-execution
# and restarting them afterward to simulate recovery.

#  ./network_outage.sh <runners> <runtime_before_outage> <outage_duration> <test_plan> <registration_token>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_SCRIPT="${SCRIPT_DIR}/runnerScript.sh"

usage() {
  echo "Usage:"
  echo "  $0 <runners> <runtime_before_outage> <outage_duration> <test_plan_path> <registration_token>"
  exit 1
}

if [[ $# -ne 5 ]]; then
  usage
fi

NUM_RUNNERS="$1"
PRE_OUTAGE_TIME="$2"
OUTAGE_TIME="$3"
TEST_PLAN="$4"
REG_TOKEN="$5"

# Resolve test plan path
if [[ -f "$TEST_PLAN" ]]; then
  ABS_PLAN="$(realpath "$TEST_PLAN")"
elif [[ -f "${SCRIPT_DIR}/${TEST_PLAN}" ]]; then
  ABS_PLAN="$(realpath "${SCRIPT_DIR}/${TEST_PLAN}")"
else
  echo "[ERROR] Test plan file not found."
  exit 1
fi

stop_all_runners() {
  echo "[INFO] Stopping all runners..."
  if [[ -f "$RUNNER_SCRIPT" ]]; then
    "$RUNNER_SCRIPT" stop
  else
    echo "[ERROR] runnerScript.sh not found."
    exit 1
  fi
}

start_runners() {
  echo "[INFO] Starting $NUM_RUNNERS runners..."
  "$RUNNER_SCRIPT" start "$NUM_RUNNERS" "$REG_TOKEN"
}

run_tests_background() {
  echo "[INFO] Launching test plan on all runners in the background..."
  for id in $(seq 1 "$NUM_RUNNERS"); do
    (
      "$HOME/runner_${id}/tap" run "$ABS_PLAN" || echo "[WARN] Runner $id test run interrupted."
    ) &
  done
}

# Main flow
echo "----------------------------------------------------"
stop_all_runners
start_runners
run_tests_background

echo "----------------------------------------------------"
echo "[INFO] Letting runners run for $PRE_OUTAGE_TIME seconds..."
sleep "$PRE_OUTAGE_TIME"

echo "----------------------------------------------------"
echo "[INFO] Simulating outage: killing test runs mid-execution..."
pkill -f "tap run" || echo "[WARN] No running tests were found to kill."

echo "[INFO] Simulating outage for $OUTAGE_TIME seconds..."
sleep "$OUTAGE_TIME"

echo "----------------------------------------------------"
echo "[INFO] Simulating recovery: restarting runners and test runs..."
stop_all_runners
start_runners
run_tests_background

echo "[INFO] Waiting for all test runs to complete..."
wait
echo "[INFO] All done."
