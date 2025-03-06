#!/usr/bin/env bash

set -e

# --- CONFIGURATION ---
STARTING_PORT=20113
MAX_RUNNERS=97
TAP_URL="https://test-automation.pw.keysight.com"

# Function to simulate running a test plan and logging data
function run_test_plan() {
  local runner_id=$1
  local test_plan=$2
  local output_file="runner_${runner_id}_metrics.log"
  
  echo "[INFO] Runner #$runner_id executing test plan: $test_plan"
  
  # Simulate workload (replace with actual test execution if needed)
  start_time=$(date +%s)
  sleep $((RANDOM % 5 + 5))  # Simulate test execution time
  end_time=$(date +%s)
  
  runtime=$((end_time - start_time))
  
  # Log the execution time
  echo "Runner #$runner_id completed in $runtime seconds" | tee "$output_file"
}

# Function to collect and output performance metrics
function collect_metrics() {
  local baseline_file="runner_1_metrics.log"
  local nth_file="runner_${N}_metrics.log"

  if [[ -f "$baseline_file" && -f "$nth_file" ]]; then
    baseline_time=$(awk '{print $5}' "$baseline_file")
    nth_time=$(awk '{print $5}' "$nth_file")

    echo "----------------------------------------------------"
    echo "[INFO] Performance Comparison:"
    echo "Baseline Runner (Runner #1): $baseline_time seconds"
    echo "Nth Runner (Runner #$N): $nth_time seconds"
    echo "Difference: $((nth_time - baseline_time)) seconds"
    echo "----------------------------------------------------"
  else
    echo "[ERROR] Could not find performance logs for comparison."
  fi
}

# Main script logic
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <number_of_runners>"
  exit 1
fi

N=$1

if (( N < 1 || N > MAX_RUNNERS )); then
  echo "[ERROR] Invalid number of runners. Must be between 1 and $MAX_RUNNERS."
  exit 1
fi

# Get test plan name from user
read -p "Enter the test plan name: " TEST_PLAN

# Start first runner and collect baseline metrics
run_test_plan 1 "$TEST_PLAN"

# Start additional runners (N-1)
for (( i=2; i<=N; i++ )); do
  run_test_plan "$i" "$TEST_PLAN" &
done

# Wait for all background runners to finish
wait

# Collect and compare performance metrics
collect_metrics
