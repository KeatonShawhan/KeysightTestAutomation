#!/usr/bin/env bash
set -e

# resolve script directory, then load our metric helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/metric_tools.sh"

# now set up where logs will go
METRICS_DIR="${SCRIPT_DIR}/metrics"
mkdir -p "$METRICS_DIR"

# --- CONFIGURATION ---
STARTING_PORT=20110
MAX_RUNNERS=97
TAP_URL="https://test-automation.pw.keysight.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
METRICS_DIR="${SCRIPT_DIR}/metrics"


# Function to check if runners directories exist
function check_runners_exist() {
  local count=0
  for i in $(seq 1 "$MAX_RUNNERS"); do
    if [[ -d "$HOME/runner_$i" ]]; then
      count=$((count + 1))
    fi
  done
  
  if [[ $count -lt $1 ]]; then
    echo "[ERROR] Not enough runners found. Found $count, but need $1."
    echo "[INFO] Please run the multi_runner.sh script to create more runners."
    exit 1
  fi
  
  echo "[INFO] Found $count runners, which is sufficient for testing."
}

# Function to verify the test plan exists in the script directory
function verify_test_plan() {
  local test_plan="$1"
  local test_plan_path="${SCRIPT_DIR}/${test_plan}"
  
  if [[ ! -f "$test_plan_path" ]]; then
    echo "[ERROR] Test plan not found: $test_plan_path"
    echo "[INFO] Please place the test plan in the same directory as this script."
    exit 1
  fi
  
  echo "[INFO] Found test plan: $test_plan_path"
}

# Function to run a test plan on a specific runner
function run_test_plan() {
  local runner_id=$1
  local test_plan=$2
  local is_baseline=$3
  local output_file="${METRICS_DIR}/runner_${runner_id}_metrics.log"
  local runner_dir="$HOME/runner_$runner_id"
  local runner_port=$((STARTING_PORT + runner_id - 1))
  local test_plan_path="${SCRIPT_DIR}/${test_plan}"
  # port might not be accurate because noisyNeighbors.sh assumes every port is open when creating runners
  echo "[INFO] Runner #$runner_id executing test plan: $test_plan (Port: $runner_port)"
  
  if [[ ! -d "$runner_dir" ]]; then
    echo "[ERROR] Runner directory $runner_dir not found."
    return 1
  fi
  
  # Capture start timestamp with millisecond precision
  local start_time=$(date +%s.%N)
  
  # Move to runner directory but use the test plan from the script directory
  cd "$runner_dir" || return 1
  
  # Execute the test plan and capture output
  if [[ "$is_baseline" == "true" ]]; then
    # For baseline, capture detailed output
    ./tap run "$test_plan_path" 2>&1 | tee "${METRICS_DIR}/runner_${runner_id}_output.log" || {
      echo "[ERROR] Failed to run test plan on runner #$runner_id."
      return 1
    }
  else
    # For concurrent runners, just capture basic output
    ./tap run "$test_plan_path" > "${METRICS_DIR}/runner_${runner_id}_output.log" 2>&1 || {
      echo "[ERROR] Failed to run test plan on runner #$runner_id."
      return 1
    }
  fi
  
  # Capture end timestamp
  local end_time=$(date +%s.%N)
  
  # Calculate runtime in seconds with millisecond precision
  local runtime=$(echo "$end_time - $start_time" | bc)
  
  # Log the execution time
  echo "runner_id=$runner_id,test_plan=$test_plan,start=$start_time,end=$end_time,runtime=$runtime" > "$output_file"
  echo "[INFO] Runner #$runner_id completed in $runtime seconds"
}


# Main script logic
clear
echo "======================================================"
echo "          NOISY NEIGHBORS PERFORMANCE TEST            "
echo "======================================================"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <number_of_runners>"
  exit 1
fi

N=$1

if (( N < 2 )); then
  echo "[ERROR] At least 2 runners are required (1 baseline + 1 concurrent)."
  exit 1
fi

if (( N > MAX_RUNNERS )); then
  echo "[ERROR] Invalid number of runners. Must be between 2 and $MAX_RUNNERS."
  exit 1
fi

# Check if we have enough runner directories
check_runners_exist "$N"

# Get test plan name from user
read -p "Enter the test plan name to execute (must be in this directory): " TEST_PLAN

# Verify the test plan exists in the script directory
verify_test_plan "$TEST_PLAN"

echo "[INFO] Starting performance test with $N runners"
echo "[INFO] Baseline: Runner #1 running solo"
echo "[INFO] Then: Runner #1 plus $(( N - 1 )) concurrent runners"

# start the metric collecting processes
start_metrics


# First: Run baseline test with just Runner #1
echo "----------------------------------------------------"
echo "[INFO] PHASE 1: Running baseline test on Runner #1 only..."
run_test_plan 1 "$TEST_PLAN" true
local_baseline_runtime=$(grep -oP 'runtime=\K[0-9.]+' "${METRICS_DIR}/runner_1_metrics.log")
echo "[INFO] Baseline completed in $local_baseline_runtime seconds"

# Now run the same test with noisy neighbors
echo "----------------------------------------------------"
echo "[INFO] PHASE 2: Running tests with $((N-1)) concurrent runners..."

# Array to hold PIDs of all runners
declare -a RUNNER_PIDS

# Start all runners concurrently
for (( i=2; i<=N; i++ )); do
  # Run each test plan in a subshell and capture its PID
  (run_test_plan "$i" "$TEST_PLAN" false) &
  RUNNER_PIDS+=($!)
  # Small delay to stagger starts slightly
  sleep 0.5
done

echo "[INFO] Started $(( N - 1 )) concurrent runners."
echo "[INFO] Waiting for all test runners to complete..."

# Wait for all runners to complete with timeout
TIMEOUT=600  # 10 min max
START_TIME=$(date +%s)

# Function to check if all runners are complete
function all_runners_complete() {
  for pid in "${RUNNER_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      # Process is still running
      return 1
    fi
  done
  # All processes have completed
  return 0
}

# Wait for all processes to finish with a timeout
COMPLETED=false
while ! $COMPLETED; do
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
  
  # Check for timeout
  if (( ELAPSED_TIME > TIMEOUT )); then
    echo "[WARNING] Timeout reached. Terminating any remaining test runners..."
    for pid in "${RUNNER_PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
    break
  fi
  
  # Check if all processes have completed
  if all_runners_complete; then
    COMPLETED=true
    echo "[INFO] All test runners have completed successfully."
  else
    echo "[INFO] Waiting for runners to complete... (${ELAPSED_TIME}s elapsed)"
    sleep 5
  fi
done

kill_metrics

echo "[INFO] Analyzing performance metrics..."

# Analyze performance impact
analyze_metrics

echo "======================================================"
echo "          TEST COMPLETED SUCCESSFULLY                 "
echo "======================================================"