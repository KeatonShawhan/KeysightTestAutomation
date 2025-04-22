#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# now set up where logs will go
METRICS_DIR="${SCRIPT_DIR}/metrics"
mkdir -p "$METRICS_DIR"
export METRICS_DIR


# resolve script directory, then load our metric helpers
source "${SCRIPT_DIR}/metric_tools.sh"


# Create a timestamped folder for this run
RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SESSION_FOLDER="${METRICS_DIR}/noisyNeighbors_${RUN_TIMESTAMP}"
mkdir -p "$SESSION_FOLDER"

RUNNER_SCRIPT="${SCRIPT_DIR}/runnerScript.sh"

# --- CONFIGURATION ---
STARTING_PORT=20110
MAX_RUNNERS=97
TAP_URL="https://test-automation.pw.keysight.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"


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
  local output_file="${SESSION_FOLDER}/runner_${runner_id}_metrics.log"
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
    ./tap run "$test_plan_path" 2>&1 | tee "${SESSION_FOLDER}/runner_${runner_id}_output.log" || {
      echo "[ERROR] Failed to run test plan on runner #$runner_id."
      return 1
    }
  else
    # For concurrent runners, just capture basic output
    ./tap run "$test_plan_path" > "${SESSION_FOLDER}/runner_${runner_id}_output.log" 2>&1 || {
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

# Function to generate a summary report
function generate_summary() {
  local test_plan="$1"
  local num_runners="$2"
  local baseline_runtime="$3"
  local summary_file="${SESSION_FOLDER}/summary.txt"
  
  {
    echo "Noisy Neighbors Performance Test Summary"
    echo "========================================"
    echo "Date/Time: $(date)"
    echo "Test Plan: $test_plan"
    echo "Total Runners: $num_runners"
    echo ""
    echo "Baseline Performance (Runner #1 solo):"
    echo "Runtime: $baseline_runtime seconds"
    echo ""
    echo "Concurrent Runners Performance:"
    
    local total_runtime=0
    local count=0
    local min_runtime=9999999
    local max_runtime=0
    
    # Skip runner 1 as it's the baseline
    for (( i=2; i<=num_runners; i++ )); do
      local metrics_file="${SESSION_FOLDER}/runner_${i}_metrics.log"
      if [[ -f "$metrics_file" ]]; then
        local runtime=$(grep -oP 'runtime=\K[0-9.]+' "$metrics_file" || echo "0.000")
        echo "Runner #$i: $runtime seconds"
        
        # Update stats
        total_runtime=$(echo "$total_runtime + $runtime" | bc)
        count=$((count + 1))
        
        # Update min/max
        if (( $(echo "$runtime < $min_runtime" | bc -l) )); then
          min_runtime=$runtime
        fi
        if (( $(echo "$runtime > $max_runtime" | bc -l) )); then
          max_runtime=$runtime
        fi
      else
        echo "Runner #$i: No metrics available"
      fi
    done
    
    echo ""
    
    # Calculate average if we have any data
    if [[ $count -gt 0 ]]; then
      local avg_runtime=$(echo "scale=3; $total_runtime / $count" | bc)
      local perf_impact=$(echo "scale=2; ($avg_runtime - $baseline_runtime) / $baseline_runtime * 100" | bc)
      
      echo "Statistics:"
      echo "  Average concurrent runtime: $avg_runtime seconds"
      echo "  Minimum runtime: $min_runtime seconds"
      echo "  Maximum runtime: $max_runtime seconds"
      echo "  Performance impact: $perf_impact% (compared to baseline)"
    else
      echo "No concurrent runner data available for statistics."
    fi
    
  } > "$summary_file"
  
  echo "[INFO] Summary report generated at: $summary_file"
}

usage() {
  echo "Usage:"
  echo "  $0 <runners> <registration_token>"
  echo ""
  echo "  <runners>                Number of runners to spin up (>=1)."
  echo "  <test_plan_path>         Path to a valid .TapFile."
  echo "  <registration_token>     Registration token for tap runner register."
  exit 1
}

# Main script logic
clear
echo "======================================================"
echo "          NOISY NEIGHBORS PERFORMANCE TEST            "
echo "======================================================"
echo "[INFO] Test data will be stored in: $SESSION_FOLDER"
echo "------------------------------------------------------"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <number_of_runners> <test_plan_path> <registration_token>"
  exit 1
fi

# 1) Parse arguments
if [[ $# -lt 3 ]]; then
  usage
fi

NUM_RUNNERS="$1"
TEST_PLAN="$2"
REG_TOKEN="$3"

if (( NUM_RUNNERS < 2 )); then
  echo "[ERROR] At least 2 runners are required (1 baseline + 1 concurrent)."
  exit 1
fi

if (( NUM_RUNNERS > MAX_RUNNERS )); then
  echo "[ERROR] Invalid number of runners. Must be between 2 and $MAX_RUNNERS."
  exit 1
fi



# 5) Stop all existing runners
echo "[INFO] Stopping any existing runners first..."
if [[ -f "$RUNNER_SCRIPT" ]]; then
  "$RUNNER_SCRIPT" stop
else
  echo "[WARNING] runnerScript.sh not found, skipping stop"
fi


# 6) Spin up the requested number of runners
echo "[INFO] Spinning up $NUM_RUNNERS runner(s)..."
if [[ -f "$RUNNER_SCRIPT" ]]; then
  "$RUNNER_SCRIPT" start "$NUM_RUNNERS" "$REG_TOKEN"
else
  echo "[ERROR] runnerScript.sh not found at '$RUNNER_SCRIPT'"
  exit 1
fi


echo "[INFO] Starting performance test with $NUM_RUNNERS runners"
echo "[INFO] Baseline: Runner #1 running solo"
echo "[INFO] Then: Runner #1 plus $(( NUM_RUNNERS - 1 )) concurrent runners"

# start the metric collecting processes
start_metrics "$SESSION_FOLDER"

# First: Run baseline test with just Runner #1
echo "----------------------------------------------------"
echo "[INFO] PHASE 1: Running baseline test on Runner #1 only..."
run_test_plan 1 "$TEST_PLAN" true
baseline_runtime=$(grep -oP 'runtime=\K[0-9.]+' "${SESSION_FOLDER}/runner_1_metrics.log")
echo "[INFO] Baseline completed in $baseline_runtime seconds"

# Now run the same test with noisy neighbors
echo "----------------------------------------------------"
echo "[INFO] PHASE 2: Running tests with $((NUM_RUNNERS-1)) concurrent runners..."

# Array to hold PIDs of all runners
declare -a RUNNER_PIDS

# Start all runners concurrently
for (( i=2; i<=NUM_RUNNERS; i++ )); do
  # Run each test plan in a subshell and capture its PID
  (run_test_plan "$i" "$TEST_PLAN" false) &
  RUNNER_PIDS+=($!)
  # Small delay to stagger starts slightly
  sleep 0.5
done

echo "[INFO] Started $(( NUM_RUNNERS - 1 )) concurrent runners."
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

# Stop all runners
stop_all_runners() {
  if [[ -f "$RUNNER_SCRIPT" ]]; then
    "$RUNNER_SCRIPT" stop
  else
    echo "[ERROR] runnerScript.sh not found at '$RUNNER_SCRIPT'"
  fi
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

kill_metrics "$SESSION_FOLDER"

echo "[INFO] Analyzing performance metrics..."

# Generate the summary report
generate_summary "$TEST_PLAN" "$NUM_RUNNERS" "$baseline_runtime"

# Analyze performance impact
analyze_metrics "$SESSION_FOLDER"

echo "======================================================"
echo "          TEST COMPLETED SUCCESSFULLY                 "
echo "======================================================"
echo "[INFO] All metrics and logs are in: $SESSION_FOLDER"