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
#   - runnerScript.sh in the same directory
#   - .NET runtime, expect, ss, unzip, curl
#   - The specified test plan must be a valid .TapFile
#

#############################################
#             CONFIG & GLOBALS             #
#############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
RUNNER_SCRIPT="${SCRIPT_DIR}/runnerScript.sh"

# now set up where logs will go
METRICS_DIR="${SCRIPT_DIR}/metrics"
mkdir -p "$METRICS_DIR"

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

# Initialize metrics for a runner
initialize_runner_metrics() {
  local runner_id="$1"
  local session_folder="$2"
  local metrics_file="${session_folder}/runner_${runner_id}_metrics.log"
  
  # Initialize the metrics file with header
  echo "runner_id=$runner_id,runs=0,total_runtime=0.000,avg_runtime=0.000" > "$metrics_file"
  # start the metric collecting processes
  start_metrics "$SESSION_FOLDER"
}

# Run a test plan (.TapFile) for a single "run" event on a specific runner.
# Updates the metrics file with cumulative information
run_test_plan() {
  local runner_id="$1"
  local run_index="$2"
  local test_plan_path="$3"
  local session_folder="$4"

  local runner_folder="$HOME/runner_${runner_id}"
  local output_file="${session_folder}/runner_${runner_id}_run_${run_index}_output.log"
  local metrics_file="${session_folder}/runner_${runner_id}_metrics.log"

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
  local runtime
  runtime=$(awk -v start="$start_ts" -v end="$end_ts" 'BEGIN {printf "%.3f", (end - start)}')

  # Update cumulative metrics - read existing metrics first
  local current_runs current_total_runtime current_avg_runtime
  if [[ -f "$metrics_file" ]]; then
    current_runs=$(grep -oP 'runs=\K[0-9]+' "$metrics_file" || echo "0")
    current_total_runtime=$(grep -oP 'total_runtime=\K[0-9.]+' "$metrics_file" || echo "0.000")
  else
    current_runs=0
    current_total_runtime=0.000
  fi
  
  # Calculate new metrics
  local new_runs=$(( current_runs + 1 ))
  local new_total_runtime=$(awk -v current="$current_total_runtime" -v runtime="$runtime" 'BEGIN {printf "%.3f", (current + runtime)}')
  local new_avg_runtime=$(awk -v total="$new_total_runtime" -v runs="$new_runs" 'BEGIN {printf "%.3f", (total / runs)}')
  
  # Update metrics file
  echo "runner_id=$runner_id,runs=$new_runs,total_runtime=$new_total_runtime,avg_runtime=$new_avg_runtime" > "$metrics_file"
  
  # Also append individual run data to a detailed log
  echo "run_index=$run_index,start=$start_ts,end=$end_ts,runtime=$runtime" >> "${session_folder}/runner_${runner_id}_detailed.log"

  cd "$SCRIPT_DIR" || true
  echo "[INFO] Runner #$runner_id (run #$run_index) completed in ${runtime}s"
}

# This function runs in the background for each runner. It loops until the
# simulation time is over, scheduling test-plan runs at random intervals (5..30s).
runner_loop() {
  local runner_id="$1"
  local deadline="$2"        # epoch seconds at which we stop scheduling new runs
  local test_plan_path="$3"  # absolute or script-relative
  local session_folder="$4"

  local run_count=1
  
  # Initialize metrics for this runner
  initialize_runner_metrics "$runner_id" "$session_folder"

  while true; do
    local now
    now=$(date +%s)

    # Check if we have already reached or passed the deadline
    if (( now >= deadline )); then
      break
    fi

    # Generate a random sleep between 5 and 30 seconds
    local sleep_sec=$(( (RANDOM % 26) + 5 ))  # [5..30]

    # If adding this sleep would cross the deadline, we won't start a new run
    if (( (now + sleep_sec) >= deadline )); then
      break
    fi

    # Sleep the random interval
    sleep "$sleep_sec"

    # Check again after sleeping
    now=$(date +%s)
    if (( now >= deadline )); then
      break
    fi

    # Time is valid, let's do another run
    run_test_plan "$runner_id" "$run_count" "$test_plan_path" "$session_folder"

    (( run_count++ ))
  done

  echo "[INFO] Runner #$runner_id finished its loop. (Total runs: $((run_count - 1)))."
}

# Stop all runners (like before). We'll just call runnerScript.sh stop
stop_all_runners() {
  if [[ -f "$RUNNER_SCRIPT" ]]; then
    "$RUNNER_SCRIPT" stop
  else
    echo "[ERROR] runnerScript.sh not found at '$RUNNER_SCRIPT'."
  fi
}

# Generate a summary report for the test run
generate_summary() {
  local session_folder="$1"
  local num_runners="$2"
  local sim_time="$3"
  local test_plan="$4"
  local summary_file="${session_folder}/summary.txt"
  
  {
    echo "Active Lab Summary Report"
    echo "=========================="
    echo "Date/Time: $(date)"
    echo "Runners: $num_runners"
    echo "Simulation Time: $sim_time seconds"
    echo "Test Plan: $test_plan"
    echo ""
    echo "Runner Statistics:"
    echo "----------------"
    
    # Calculate total runs and average runtime across all runners
    local total_runs=0
    local all_runtimes=()
    
    for r in $(seq 1 "$num_runners"); do
      local metrics_file="${session_folder}/runner_${r}_metrics.log"
      if [[ -f "$metrics_file" ]]; then
        local runs=$(grep -oP 'runs=\K[0-9]+' "$metrics_file" || echo "0")
        local avg_runtime=$(grep -oP 'avg_runtime=\K[0-9.]+' "$metrics_file" || echo "0.000")
        local total_runtime=$(grep -oP 'total_runtime=\K[0-9.]+' "$metrics_file" || echo "0.000")
        
        echo "Runner #$r: $runs runs, avg runtime: ${avg_runtime}s, total runtime: ${total_runtime}s"
        
        total_runs=$((total_runs + runs))
        all_runtimes+=("$avg_runtime")
      else
        echo "Runner #$r: No metrics available"
      fi
    done
    
    echo ""
    echo "Total runs across all runners: $total_runs"
    
    # Calculate overall average if we have runtimes
    if [[ ${#all_runtimes[@]} -gt 0 ]]; then
      local sum=0
      for rt in "${all_runtimes[@]}"; do
        sum=$(awk -v sum="$sum" -v rt="$rt" 'BEGIN {printf "%.3f", (sum + rt)}')
      done
      local overall_avg=$(awk -v sum="$sum" -v count="${#all_runtimes[@]}" 'BEGIN {printf "%.3f", (sum / count)}')
      echo "Overall average runtime: ${overall_avg}s"
    fi
    
  } > "$summary_file"
  
  echo "[INFO] Summary report generated at: $summary_file"
}

#############################################
#              MAIN SCRIPT LOGIC           #
#############################################

# 1) Parse arguments
if [[ $# -lt 4 ]]; then
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
elif [[ -f "${SCRIPT_DIR}/../../taprunner/${USER_TEST_PLAN}" ]]; then
  # Fallback to taprunner directory relative to repo root
  ABS_TEST_PLAN="$(cd "${SCRIPT_DIR}/../../taprunner"; pwd)/$(basename "$USER_TEST_PLAN")"
else
  echo "[ERROR] Test plan not found at:"
  echo " - '$USER_TEST_PLAN'"
  echo " - '${SCRIPT_DIR}/${USER_TEST_PLAN}'"
  echo " - '../../taprunner/${USER_TEST_PLAN}'"
  exit 1
fi

# Create session folder
RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SESSION_FOLDER="${METRICS_DIR}/activeLab_${RUN_TIMESTAMP}"
mkdir -p "$SESSION_FOLDER"

# Export & load metrics tooling
export METRICS_DIR="$SESSION_FOLDER"
source "${SCRIPT_DIR}/metric_tools.sh"

echo "----------------------------------------------------"
echo "[INFO] This run's metrics/logs will be in: $SESSION_FOLDER"

# 5) Stop all runners (clean slate)
echo "[INFO] Stopping any existing runners first..."
stop_all_runners

# 6) Spin up the requested number of runners
echo "[INFO] Spinning up $NUM_RUNNERS runner(s)..."
if [[ -f "$RUNNER_SCRIPT" ]]; then
  "$RUNNER_SCRIPT" start "$NUM_RUNNERS" "$REG_TOKEN"
else
  echo "[ERROR] runnerScript.sh not found at '$RUNNER_SCRIPT'"
  exit 1
fi

# 7) Start the simulation
echo "----------------------------------------------------"
echo "[INFO] Beginning simulation with $NUM_RUNNERS runners for $SIM_TIME seconds."
SIM_START=$(date +%s)
DEADLINE=$(( SIM_START + SIM_TIME ))

# Spawn a background job for each runner
declare -a RUNNER_PIDS=()
for runner_id in $(seq 1 "$NUM_RUNNERS"); do
  (
    runner_loop "$runner_id" "$DEADLINE" "$ABS_TEST_PLAN" "$SESSION_FOLDER"
  ) &
  RUNNER_PIDS+=($!)
done

# Wait for all runners to complete their loop
echo "[INFO] All runners started their loops. Waiting for them to finish..."
for pid in "${RUNNER_PIDS[@]}"; do
  wait "$pid"
done

echo "[INFO] All runner loops have completed. This means no new test plans will be started."

# 8) Generate a summary report
generate_summary "$SESSION_FOLDER" "$NUM_RUNNERS" "$SIM_TIME" "$ABS_TEST_PLAN"

# 9) Stop all runners (they might be idle at this point)
echo "----------------------------------------------------"
echo "[INFO] Simulation time ended and all test-plan loops are done. Stopping all runners."
stop_all_runners

generate_charts "$SESSION_FOLDER"

kill_metrics "$SESSION_FOLDER"

echo "----------------------------------------------------"
echo "[INFO] Done. Metrics and outputs are in: $SESSION_FOLDER"
echo "[INFO] End of script."
