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

# Function to run a test plan on a specific runner
function run_test_plan() {
  local runner_id=$1
  local test_plan=$2
  local is_baseline=$3
  local output_file="${METRICS_DIR}/runner_${runner_id}_metrics.log"
  local runner_dir="$HOME/runner_$runner_id"
  local runner_port=$((STARTING_PORT + runner_id - 1))
  
  echo "[INFO] Runner #$runner_id executing test plan: $test_plan (Port: $runner_port)"
  
  if [[ ! -d "$runner_dir" ]]; then
    echo "[ERROR] Runner directory $runner_dir not found."
    return 1
  fi
  
  # Capture start timestamp with millisecond precision
  local start_time=$(date +%s.%N)
  
  # Actually run the test plan on the runner
  cd "$runner_dir" || return 1
  
  # Execute the test plan and capture output
  if [[ "$is_baseline" == "true" ]]; then
    # For baseline, capture detailed output
    ./tap run "$test_plan" 2>&1 | tee "${METRICS_DIR}/runner_${runner_id}_output.log" || {
      echo "[ERROR] Failed to run test plan on runner #$runner_id."
      return 1
    }
  else
    # For concurrent runners, just capture basic output
    ./tap run "$test_plan" > "${METRICS_DIR}/runner_${runner_id}_output.log" 2>&1 || {
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
  local pid=$$
  local output_file="${METRICS_DIR}/resource_usage.log"
  
  echo "timestamp,cpu_percent,memory_kb" > "$output_file"
  
  while kill -0 $pid 2>/dev/null; do
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
  local max_runner=0
  local min_runtime=9999
  local min_runner=0
  
  echo "----------------------------------------------------"
  echo "[INFO] Performance Analysis:"
  
  # Extract baseline metrics
  if [[ -f "$baseline_file" ]]; then
    local baseline_data=$(cat "$baseline_file")
    local baseline_runtime=$(echo "$baseline_data" | grep -oP 'runtime=\K[0-9.]+')
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
      local data=$(cat "$metrics_file")
      local runtime=$(echo "$data" | grep -oP 'runtime=\K[0-9.]+')
      
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
      
      # Calculate slowdown compared to baseline
      local slowdown=$(echo "scale=2; ($runtime / $baseline_runtime - 1) * 100" | bc)
      echo "Runner #$i: $runtime seconds (${slowdown}% slower than baseline)"
    fi
  done
  
  # Calculate average (excluding baseline)
  if (( N > 1 )); then
    local avg_runtime=$(echo "scale=2; $total_runtime / (${N} - 1)" | bc)
    local avg_slowdown=$(echo "scale=2; ($avg_runtime / $baseline_runtime - 1) * 100" | bc)
    
    echo "----------------------------------------------------"
    echo "Summary Statistics:"
    echo "Fastest Runner: #$min_runner ($min_runtime seconds)"
    echo "Slowest Runner: #$max_runner ($max_runtime seconds)"
    echo "Average Runtime: $avg_runtime seconds"
    echo "Average Slowdown: ${avg_slowdown}%"
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
read -p "Enter the test plan name to execute: " TEST_PLAN

echo "[INFO] Starting performance test with $N runners"
echo "[INFO] Baseline: Runner #1 running solo"
echo "[INFO] Then: Runner #1 plus $(( N - 1 )) concurrent runners"

# Start resource monitoring in the background
monitor_resources &
MONITOR_PID=$!

# First: Run baseline test with just Runner #1
echo "----------------------------------------------------"
echo "[INFO] PHASE 1: Running baseline test on Runner #1 only..."
run_test_plan 1 "$TEST_PLAN" true
baseline_runtime=$(grep -oP 'runtime=\K[0-9.]+' "${METRICS_DIR}/runner_1_metrics.log")
echo "[INFO] Baseline completed in $baseline_runtime seconds"

# Now run the same test with noisy neighbors
echo "----------------------------------------------------"
echo "[INFO] PHASE 2: Running tests with $((N-1)) concurrent runners..."

# Start Runner #1 again (for comparative performance)
run_test_plan 1 "$TEST_PLAN" true &

# Start all other runners concurrently
for (( i=2; i<=N; i++ )); do
  run_test_plan "$i" "$TEST_PLAN" false &
done

# Wait for all background runners to finish
wait

# Stop resource monitoring
kill $MONITOR_PID 2>/dev/null || true

# Analyze performance impact
analyze_metrics

echo "======================================================"
echo "          TEST COMPLETED SUCCESSFULLY                 "
echo "======================================================"