#!/usr/bin/env bash
#
# network_outage.sh
#
# Simulates a network outage in a test automation lab. Spins up runners,
# executes a test plan for a while, simulates a network outage by pausing
# runners mid-run, then resumes them and completes the remaining runs.
#
# Usage:
#   ./network_outage.sh <runners> <runtime_before_outage_sec> <outage_duration_sec> <test_plan_path> <registration_token>

set -e

# Absolute path to the folder that holds *this* script …
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# … and to the repo root (one level up from test-scripts/)
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." &>/dev/null && pwd)"

RUNNER_SCRIPT="${SCRIPT_DIR}/runnerScript.sh"

# Drop all metrics in <repo-root>/metrics instead of test-scripts/metrics
METRICS_DIR="${REPO_ROOT}/metrics"
mkdir -p "${METRICS_DIR}"

usage() {
  echo "Usage: $0 <runners> <runtime_before_outage> <outage_duration> <test_plan_path> <registration_token>"
  exit 1
}

check_command_exists() {
  command -v "$1" &>/dev/null || { echo "[ERROR] '$1' not found"; exit 1; }
}

check_dependencies() {
  for cmd in dotnet ss unzip curl; do
    check_command_exists "$cmd"
  done
}

pause_runners() {
  echo "[INFO] Pausing OpenTAP processes…"
  mapfile -t PIDS < <(
    ps aux | grep -E '(./tap |bin/tap|dotnet.*OpenTap)' | grep -v grep | awk '{print $2}'
  )
  if (( ${#PIDS[@]} )); then
    echo "  → pausing PIDs: ${PIDS[*]}"
    kill -STOP "${PIDS[@]}"
  else
    echo "[WARN] No OpenTAP processes found to pause."
  fi
}

resume_runners() {
  echo "[INFO] Resuming OpenTAP processes…"
  if (( ${#PIDS[@]} )); then
    echo "  → resuming PIDs: ${PIDS[*]}"
    kill -CONT "${PIDS[@]}"
  fi
}


run_test_plan() {
  local rid=$1 plan=$2 session=$3
  local folder="$HOME/runner_$rid"
  local out="$session/runner_${rid}_out.log"
  local met="$session/runner_${rid}_metrics.log"
  mkdir -p "${session}"
  cd "$folder" || return 1
  local start=$(date +%s.%N)
  ./tap run "$plan" &> "$out" || echo "[ERROR] runner $rid failed"
  local end=$(date +%s.%N)
  local dur=$(awk -v s="$start" -v e="$end" 'BEGIN{printf"%.3f",e-s}')
  echo "runner_id=$rid,start=$start,end=$end,duration=$dur" | tee "$met"
}

runner_loop() {
  local rid=$1 plan=$2 session=$3
  run_test_plan "$rid" "$plan" "$session"
}

stop_all_runners() {
  [[ -f "$RUNNER_SCRIPT" ]] && "$RUNNER_SCRIPT" stop
}

#############################################
#                MAIN LOGIC                #
#############################################

[[ $# -ne 5 ]] && usage
NUM_RUNNERS=$1
PRE_SEC=$2
OUTAGE_SEC=$3
PLAN=$4
TOKEN=$5

check_dependencies

# resolve plan
if [[ -f "$PLAN" ]]; then
  PLAN=$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")
elif [[ -f "$SCRIPT_DIR/$PLAN" ]]; then
  PLAN="$SCRIPT_DIR/$PLAN"
elif [[ -f "$SCRIPT_DIR/../../taprunner/$PLAN" ]]; then
  PLAN="$(cd "$SCRIPT_DIR/../../taprunner" && pwd)/$(basename "$PLAN")"
else
  echo "[ERROR] Plan not found:"
  echo " - $PLAN"
  echo " - $SCRIPT_DIR/$PLAN"
  echo " - $SCRIPT_DIR/../../taprunner/$PLAN"
  exit 1
fi


# metrics session
TS=$(date +%Y%m%d_%H%M%S)
SESSION="$METRICS_DIR/networkOutage_$TS"
mkdir -p "$SESSION"
export METRICS_DIR="$SESSION"
source "$SCRIPT_DIR/metric_tools.sh"
start_metrics "$SESSION"

# clean and start runners
echo "[INFO] Cleaning existing runners..."
stop_all_runners

echo "[INFO] Starting $NUM_RUNNERS runners..."
"$RUNNER_SCRIPT" start "$NUM_RUNNERS" "$TOKEN"

# Better: wait for each runner directory/log before starting test plan loops
echo "[INFO] Waiting for all $NUM_RUNNERS runner dirs to be created..."
for id in $(seq 1 "$NUM_RUNNERS"); do
  dir="$HOME/runner_${id}"
  until [[ -f "$dir/runner.log" ]]; do
    sleep 0.5
  done
  echo "[INFO] Runner #${id} is ready (found $dir/runner.log)."
done

# launch loops background before outage
echo "[INFO] Running test plan for $PRE_SEC seconds before outage..."
declare -a BG_PIDS=()
for id in $(seq 1 "$NUM_RUNNERS"); do
  runner_loop "$id" "$PLAN" "$SESSION" &
  BG_PIDS+=( $! )
done

# 2) Let them run normally for PRE_SEC seconds
sleep "$PRE_SEC"

# wait PRE_SEC then pause
echo "[INFO] Simulating network outage: pausing runners for $OUTAGE_SEC s"
pause_runners
sleep "$OUTAGE_SEC"
echo "[INFO] Restoring network: resuming runners"
resume_runners

# wait loops to finish after resume for remaining PRE_SEC
echo "[INFO] Waiting for runners to finish remaining runs..."
for pid in "${BG_PIDS[@]}"; do wait "$pid"; done

# teardown
echo "[INFO] Stopping all runners"
stop_all_runners

generate_charts "$SESSION"
kill_metrics "$SESSION"

echo "[INFO] Done. Logs in $SESSION"
