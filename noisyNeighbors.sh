#!/usr/bin/env bash

set -e

# --- CONFIGURATION ---
STARTING_PORT=20113
MAX_RUNNERS=97
TAP_URL="https://test-automation.pw.keysight.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
METRICS_DIR="${SCRIPT_DIR}/metrics"

# Create metrics directory if it doesn't exist
mkdir -p "$METRICS_DIR"

# Function to check if runner directories exist
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

# Function to collect resource usage during test execution
function monitor_resources() {
  local output_file="${METRICS_DIR}/resource_usage.log"
  
  echo "timestamp,cpu_percent,memory_kb" > "$output_file"
  
  while [[ -f "${METRICS_DIR}/.monitoring_active" ]]; do
    # Get CPU and memory usage for all test processes
    local timestamp=$(date +%s)
    local cpu_usage=$(ps -e -o pcpu= | awk '{sum+=$1} END {print sum}')
    local mem_usage=$(ps -e -o rss= | awk '{sum+=$1} END {print sum}')
    
    echo "$timestamp,$cpu_usage,$mem_usage" >> "$output_file"
    sleep 1
  done
}

# Function to analyze and display performance metrics
function analyze_metrics() {
  local baseline_file="${METRICS_DIR}/runner_1_metrics.log"
  local total_runtime=0
  local max_runtime=0
  local max_runner=1
  local min_runtime=9999999  # High enough to ensure proper min selection
  local min_runner=1
  local fastest_runtime=9999999  # Initialize for comparison
  local fastest_runner=1
  
  echo "----------------------------------------------------"
  echo "[INFO] Performance Analysis:"
  
  # Extract baseline metrics
  if [[ -f "$baseline_file" ]]; then
    local baseline_data=$(grep -oP 'runtime=\K[0-9.]+' "$baseline_file")
    if [[ -z "$baseline_data" ]]; then
      echo "[ERROR] Baseline runner log exists, but no runtime data found."
      return 1
    fi
    local baseline_runtime=$baseline_data
    echo "Baseline Runner (Runner #1): $baseline_runtime seconds"
  else
    echo "[ERROR] Could not find baseline metrics file."
    return 1
  fi

  # Analyze metrics for all runners
  echo "----------------------------------------------------"
  echo "Individual Runner Performance:"
  for i in $(seq 2 "$N"); do
    local metrics_file="${METRICS_DIR}/runner_${i}_metrics.log"
    if [[ -f "$metrics_file" ]]; then
      local runtime=$(grep -oP 'runtime=\K[0-9.]+' "$metrics_file")

      # Validate runtime extraction
      if [[ -z "$runtime" ]]; then
        echo "[WARNING] Could not extract runtime for Runner #$i. Skipping..."
        continue
      fi
      
      # Track min/max
      if (( $(echo "$runtime > $max_runtime" | bc -l) )); then
        max_runtime=$runtime
        max_runner=$i
      fi
      
      if (( $(echo "$runtime < $min_runtime" | bc -l) )); then
        min_runtime=$runtime
        min_runner=$i
      fi
      
      total_runtime=$(echo "$total_runtime + $runtime" | bc)
      
      # Compare to fastest runtime (for percentage accuracy)
      if (( $(echo "$runtime < $fastest_runtime" | bc -l) )); then
        fastest_runtime=$runtime
        fastest_runner=$i
      fi
      
      # Calculate slowdown compared to baseline with increased precision
      local slowdown=$(echo "scale=4; (($runtime / $baseline_runtime) - 1) * 100" | bc)
      
      # Format with more precision to capture small differences
      slowdown=$(printf "%.4f" "$slowdown")  # Using 4 decimal places instead of 2

      echo "Runner #$i: ${runtime} seconds (${slowdown}% slower than baseline)"
    else
      echo "[WARNING] Missing metrics file for Runner #$i. Skipping..."
    fi
  done

  # Calculate average (excluding baseline)
  if (( N > 1 )); then
    local avg_runtime=$(echo "scale=4; $total_runtime / (${N} - 1)" | bc)
    local avg_slowdown=$(echo "scale=4; ($avg_runtime / $baseline_runtime - 1) * 100" | bc)
    
    # Format with consistent precision
    avg_runtime=$(printf "%.4f" "$avg_runtime")
    avg_slowdown=$(printf "%.4f" "$avg_slowdown")
    
    echo "----------------------------------------------------"
    echo "Summary Statistics:"
    echo "Fastest Runner: #$min_runner ($min_runtime seconds)"
    echo "Slowest Runner: #$max_runner ($max_runtime seconds)"
    echo "Average Runtime: $avg_runtime seconds"
    echo "Average Slowdown: ${avg_slowdown}%"
    
    # Generate a summary file for easy reference with improved precision
    {
      echo "Test Plan: $TEST_PLAN"
      echo "Date: $(date)"
      echo "Number of Runners: $N"
      echo ""
      echo "Baseline Runtime: $baseline_runtime seconds"
      echo "Average Runtime with Noisy Neighbors: $avg_runtime seconds"
      echo "Average Performance Impact: ${avg_slowdown}% slower"
      echo "Fastest Runner: #$min_runner ($min_runtime seconds)"
      echo "Slowest Runner: #$max_runner ($max_runtime seconds)"
    } > "${METRICS_DIR}/summary_report.txt"
    
    echo "A summary report has been saved to: ${METRICS_DIR}/summary_report.txt"
  fi

  echo "----------------------------------------------------"
  echo "Performance impact analysis complete. Detailed logs available in the $METRICS_DIR directory."
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

# Clean up previous metrics
rm -rf "${METRICS_DIR}"/*.log

# Get test plan name from user
read -p "Enter the test plan name to execute (must be in this directory): " TEST_PLAN

# Verify the test plan exists in the script directory
verify_test_plan "$TEST_PLAN"

echo "[INFO] Starting performance test with $N runners"
echo "[INFO] Baseline: Runner #1 running solo"
echo "[INFO] Then: Runner #1 plus $(( N - 1 )) concurrent runners"

# Create a file flag to indicate monitoring should continue
touch "${METRICS_DIR}/.monitoring_active"

# Start resource monitoring in the background
monitor_resources &
MONITOR_PID=$!

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
TIMEOUT=80  # 80 seconds max
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

# Stop resource monitoring by removing the flag file
rm -f "${METRICS_DIR}/.monitoring_active"
# Give the monitoring process a moment to detect the flag is gone
sleep 2
# Kill the monitoring process if it's still running
if kill -0 $MONITOR_PID 2>/dev/null; then
  kill $MONITOR_PID
fi

echo "[INFO] Analyzing performance metrics..."

# Analyze performance impact
analyze_metrics

echo "======================================================"
echo "          TEST COMPLETED SUCCESSFULLY                 "
echo "======================================================"