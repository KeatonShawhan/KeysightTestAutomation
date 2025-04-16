#!/usr/bin/env bash
#
# active_lab.sh
#
# Spins up a specified number of OpenTAP runners on a Raspberry Pi, then for a
# specified "simulation time," each runner continuously runs a given .TapFile
# at random intervals of 5-30s in parallel. Once the simulation time is up,
# the script waits for any in-progress test plans to finish, then tears down
# all runners.
#
# Usage:
#   ./active_lab.sh <runners> <simulation_time_seconds> <test_plan_path> <registration_token>
#
# Example:
#   ./active_lab.sh 5 120 MyPlan.TapPlan <myRegToken>
#   (5 runners, 120s simulation time, test plan MyPlan.TapPlan, provided registration token)
#
# Requirements:
#   - runnerScript.sh and metric_tools.sh in the same directory
#   - .NET runtime, expect, ss, unzip, curl, iostat, mpstat
#
#############################################
#             CONFIG & GLOBALS             #
#############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
RUNNER_SCRIPT="${SCRIPT_DIR}/runnerScript.sh"

# Base metrics directory; per-run logs will go under here
METRICS_DIR="${SCRIPT_DIR}/metrics"
mkdir -p "${METRICS_DIR}"

# Source metric collection and graphing utilities
source "${SCRIPT_DIR}/metric_tools.sh"

#############################################
#        UTILITY & HELPER FUNCTIONS        #
#############################################

usage() {
  echo "Usage:"
  echo "  $0 <runners> <simulation_time_sec> <test_plan_path> <registration_token>"
  echo ""
  echo "  <runners>                Number of runners to spin up (>=1)."
  echo "  <simulation_time_sec>    Total time in seconds for random scheduling (>=30)."
  echo "  <test_plan_path>         Path to a valid .TapFile."
  echo "  <registration_token>     Registration token for tap runner register."
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
  for cmd in dotnet expect ss unzip curl; do
    check_command_exists "$cmd" || missing=1
  done
  if (( missing )); then
    echo "[ERROR] Missing one or more required commands. Exiting."
    exit 1
  fi
}

# Run a test plan (.TapFile) for a single "run" event on a specific runner.
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
  echo "[INFO] Runner #$runner_id (run #$run_index) starting test plan: $test_plan_path"
  if ! ./tap run "$test_plan_path" &> "$output_file"; then
    echo "[ERROR] Runner #$runner_id encountered an error running $test_plan_path (run #$run_index)"
  fi
  end_ts=$(date +%s.%N)

  local duration
  duration=$(awk -v start="$start_ts" -v end="$end_ts" 'BEGIN {printf "%.3f", (end - start)}')

  echo "runner_id=$runner_id,run_index=$run_index,start=$start_ts,end=$end_ts,runtime=$duration" > "$metrics_file"
  cd "$SCRIPT_DIR" || true
  echo "[INFO] Runner #$runner_id (run #$run_index) completed in ${duration}s"
}

# This function runs in the background for each runner. It loops until the
# simulation time is over, scheduling test-plan runs at random intervals (5..30s).
runner_loop() {
  local runner_id="$1"
  local deadline="$2"        # epoch seconds at which we stop scheduling new runs
  local test_plan_path="$3"  # absolute or script-relative
  local session_folder="$4"
  local run_count=1

  while true; do
    local now=$(date +%s)
    (( now >= deadline )) && break

    # random sleep 5-30s
    local sleep_sec=$(( (RANDOM % 26) + 5 ))
    (( now + sleep_sec >= deadline )) && break

    sleep "$sleep_sec"
    now=$(date +%s)
    (( now >= deadline )) && break

    run_test_plan "$runner_id" "$run_count" "$test_plan_path" "$session_folder"
    (( run_count++ ))
  done

  echo "[INFO] Runner #$runner_id finished its loop. (Last run index was $((run_count - 1)))."
}

# Stop all runners (like before). We'll just call runnerScript.sh stop
stop_all_runners() {
  if [[ -f "$RUNNER_SCRIPT" ]]; then
    "$RUNNER_SCRIPT" stop
  else
    echo "[ERROR] runnerScript.sh not found at '$RUNNER_SCRIPT'."
  fi
}

#############################################
#              MAIN SCRIPT LOGIC           #
#############################################

# 1) Parse arguments
if [[ $# -ne 4 ]]; then
  usage
fi

NUM_RUNNERS="$1"
SIM_TIME="$2"
USER_TEST_PLAN="$3"
REG_TOKEN="$4"

# Basic validation
if (( NUM_RUNNERS < 1 )); then
  echo "[ERROR] Number of runners must be >= 1."
  exit 1
fi

if (( SIM_TIME < 30 )); then
  echo "[ERROR] Simulation time must be at least 30 seconds."
  exit 1
fi

# 2) Check dependencies
check_dependencies

# 3) Resolve test plan path relative to script directory if needed
ABS_TEST_PLAN=""
if [[ -f "$USER_TEST_PLAN" ]]; then
  # If user gave an absolute path or a relative path from current shell
  ABS_TEST_PLAN="$(cd "$(dirname "$USER_TEST_PLAN")"; pwd)/$(basename "$USER_TEST_PLAN")"
elif [[ -f "${SCRIPT_DIR}/${USER_TEST_PLAN}" ]]; then
  # If the file exists relative to the script's directory
  ABS_TEST_PLAN="$(cd "$SCRIPT_DIR"; pwd)/$(basename "$USER_TEST_PLAN")"
else
  echo "[ERROR] Test plan not found at '$USER_TEST_PLAN' nor '$SCRIPT_DIR/$USER_TEST_PLAN'"
  exit 1
fi

# 4) Create a dated subfolder in metrics to store logs for this run
RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SESSION_FOLDER="${METRICS_DIR}/${RUN_TIMESTAMP}"
mkdir -p "$SESSION_FOLDER"
echo "----------------------------------------------------"
echo "[INFO] Metrics/logs will be in: $SESSION_FOLDER"

# Override METRICS_DIR for metric_tools to write into this session
METRICS_DIR="$SESSION_FOLDER"
mkdir -p "${METRICS_DIR}/charts"

# 5) Clean slate: stop any existing runners
echo "[INFO] Stopping existing runners..."
stop_all_runners

# 6) Spin up runners
echo "[INFO] Spinning up $NUM_RUNNERS runner(s)..."
[[ -f "$RUNNER_SCRIPT" ]] && "$RUNNER_SCRIPT" start "$NUM_RUNNERS" "$REG_TOKEN" \
  || { echo "[ERROR] runnerScript.sh not found."; exit 1; }

# 7) Start simulation and monitoring
echo "----------------------------------------------------"
echo "[INFO] Beginning simulation: $NUM_RUNNERS runners for $SIM_TIME seconds."
SIM_START=$(date +%s)
DEADLINE=$((SIM_START + SIM_TIME))

# Launch resource monitoring in background
touch "${METRICS_DIR}/.monitoring_active"
declare -a MONITOR_PIDS=()
monitor_resources        & MONITOR_PIDS+=("$!")
monitor_detailed_cpu     & MONITOR_PIDS+=("$!")
monitor_cpu_cores        & MONITOR_PIDS+=("$!")
monitor_detailed_memory  & MONITOR_PIDS+=("$!")
monitor_network_connections & MONITOR_PIDS+=("$!")

# Spawn each runner loop
declare -a RUNNER_PIDS=()
for runner_id in $(seq 1 "$NUM_RUNNERS"); do
  ( runner_loop "$runner_id" "$DEADLINE" "$ABS_TEST_PLAN" "$SESSION_FOLDER" ) &
  RUNNER_PIDS+=("$!")
done

echo "[INFO] All runners started. Waiting for completion..."
for pid in "${RUNNER_PIDS[@]}"; do wait "$pid"; done

echo "[INFO] Runner loops complete."

# 8) Tear down runners
echo "----------------------------------------------------"
echo "[INFO] Simulation ended. Stopping runners."
stop_all_runners

# 9) Stop monitoring
rm -f "${METRICS_DIR}/.monitoring_active"
sleep 2
for pid in "${MONITOR_PIDS[@]}"; do
  kill "$pid" &>/dev/null || true
done

# 10) Analyze and graph metrics
echo "[INFO] Analyzing and graphing performance metrics..."
analyze_metrics

# 11) Finish

echo "----------------------------------------------------"
echo "[INFO] Done. Results in: $SESSION_FOLDER"
echo "[INFO] End of script."
