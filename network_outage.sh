#!/usr/bin/env bash
#
# network_outage.sh
#
# Simulates a network outage in a test automation lab. Spins up runners,
# executes a test plan for a while, simulates a network outage by stopping
# runners, then brings them back online and resumes execution.
#
# Usage:
#   ./network_outage.sh <runners> <runtime_before_outage_sec> <outage_duration_sec> <test_plan_path> <registration_token>
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
RUNNER_SCRIPT="${SCRIPT_DIR}/runnerScript.sh"
METRICS_DIR="${SCRIPT_DIR}/metrics"
mkdir -p "${METRICS_DIR}"

usage() {
  echo "Usage:"
  echo "  $0 <runners> <runtime_before_outage> <outage_duration> <test_plan_path> <registration_token>"
  exit 1
}

check_command_exists() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] '$cmd' is not installed or not in PATH."
    return 1
  fi
  return 0
}

check_dependencies() {
  local missing=0
  for cmd in dotnet ss unzip curl; do
    check_command_exists "$cmd" || missing=1
  done
  if (( missing )); then
    echo "[ERROR] Missing one or more required commands. Exiting."
    exit 1
  fi
}

run_test_plan() {
  local runner_id="$1"
  local run_index="$2"
  local test_plan_path="$3"
  local session_folder="$4"

  local runner_folder="$HOME/runner_${runner_id}"
  local output_file="${session_folder}/runner_${runner_id}_run_${run_index}_output.log"
  local metrics_file="${session_folder}/runner_${runner_id}_run_${run_index}_metrics.log"

  if [[ ! -d "$runner_folder" ]]; then
    echo "[ERROR] Runner directory not found: $runner_folder"
    return 1
  fi

  local start_ts end_ts
  start_ts=$(date +%s.%N)

  cd "$runner_folder" || return 1
  echo "[INFO] Runner #$runner_id (run #$run_index) starting test plan..."

  if ! ./tap run "$test_plan_path" &> "$output_file"; then
    echo "[ERROR] Runner #$runner_id error on test plan (run #$run_index)"
  fi

  end_ts=$(date +%s.%N)
  local duration
  duration=$(awk -v start="$start_ts" -v end="$end_ts" 'BEGIN {printf "%.3f", (end - start)}')

  echo "runner_id=$runner_id,run_index=$run_index,start=$start_ts,end=$end_ts,runtime=$duration" > "$metrics_file"

  cd "$SCRIPT_DIR" || true
  echo "[INFO] Runner #$runner_id (run #$run_index) completed in ${duration}s"
}

runner_loop() {
  local runner_id="$1"
  local deadline="$2"
  local test_plan_path="$3"
  local session_folder="$4"
  local run_count=1

  while true; do
    local now=$(date +%s)
    if (( now >= deadline )); then
      break
    fi

    run_test_plan "$runner_id" "$run_count" "$test_plan_path" "$session_folder"
    (( run_count++ ))

    local sleep_sec=$(( (RANDOM % 5) + 2 )) # Shorter sleep (2–6s)
    sleep "$sleep_sec"
  done

  echo "[INFO] Runner #$runner_id exiting after $((run_count - 1)) runs."
}

stop_all_runners() {
  if [[ -f "$RUNNER_SCRIPT" ]]; then
    "$RUNNER_SCRIPT" stop
  else
    echo "[ERROR] runnerScript.sh not found."
  fi
}

#############################################
#              MAIN SCRIPT LOGIC           #
#############################################

if [[ $# -ne 5 ]]; then usage; fi

NUM_RUNNERS="$1"
RUNTIME_BEFORE_OUTAGE="$2"
OUTAGE_DURATION="$3"
USER_TEST_PLAN="$4"
REG_TOKEN="$5"

check_dependencies

# Resolve test plan path
if [[ -f "$USER_TEST_PLAN" ]]; then
  ABS_TEST_PLAN="$(cd "$(dirname "$USER_TEST_PLAN")"; pwd)/$(basename "$USER_TEST_PLAN")"
elif [[ -f "${SCRIPT_DIR}/${USER_TEST_PLAN}" ]]; then
  ABS_TEST_PLAN="${SCRIPT_DIR}/${USER_TEST_PLAN}"
else
  echo "[ERROR] Test plan not found: $USER_TEST_PLAN"
  exit 1
fi



# Metrics session folder
RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SESSION_FOLDER="${METRICS_DIR}/networkOutage_${RUN_TIMESTAMP}"
mkdir -p "$SESSION_FOLDER"

# Export & load metrics tooling
export METRICS_DIR="$SESSION_FOLDER"
source "${SCRIPT_DIR}/metric_tools.sh"

# start the metric collection
start_metrics "$SESSION_FOLDER"

echo "[INFO] Stopping any existing runners..."
stop_all_runners

echo "[INFO] Spinning up $NUM_RUNNERS runner(s)..."
"$RUNNER_SCRIPT" start "$NUM_RUNNERS" "$REG_TOKEN"

# Start baseline activity
echo "[INFO] Running baseline test plan for $RUNTIME_BEFORE_OUTAGE seconds..."
declare -a PIDS=()
END_TIME=$(( $(date +%s) + RUNTIME_BEFORE_OUTAGE ))
for runner_id in $(seq 1 "$NUM_RUNNERS"); do
  runner_loop "$runner_id" "$END_TIME" "$ABS_TEST_PLAN" "$SESSION_FOLDER" &
  PIDS+=($!)
done

for pid in "${PIDS[@]}"; do wait "$pid"; done

# Simulate outage
echo "[INFO] Simulating network outage by stopping runners for $OUTAGE_DURATION seconds..."
stop_all_runners
sleep "$OUTAGE_DURATION"

# Reconnect phase
echo "[INFO] Reconnecting: restarting all runners..."
"$RUNNER_SCRIPT" start "$NUM_RUNNERS" "$REG_TOKEN"

# Run post-outage plan
POST_OUTAGE_DURATION=15
RECONNECT_END_TIME=$(( $(date +%s) + POST_OUTAGE_DURATION ))
echo "[INFO] Running post-outage test plans for $POST_OUTAGE_DURATION seconds..."
PIDS=()
for runner_id in $(seq 1 "$NUM_RUNNERS"); do
  runner_loop "$runner_id" "$RECONNECT_END_TIME" "$ABS_TEST_PLAN" "$SESSION_FOLDER" &
  PIDS+=($!)
done

for pid in "${PIDS[@]}"; do wait "$pid"; done

# Tear down runners after post-outage
echo "[INFO] Stopping all runners after post-outage run."
stop_all_runners

generate_charts "$SESSION_FOLDER"

kill_metrics "$SESSION_FOLDER"

echo "----------------------------------------------------"
echo "[INFO] Simulation complete. Logs in: $SESSION_FOLDER"