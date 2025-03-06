#!/usr/bin/env bash

set -e

# --- CONFIGURATION ---
STARTING_PORT=20113
MAX_RUNNERS=97
MAX_PORT=20220
TAP_URL="https://test-automation.pw.keysight.com"
OPENTAP_BASE_DOWNLOAD="https://packages.opentap.io/4.0/Objects/Packages/OpenTAP?os=Linux&architecture=arm64"
RUNNER_PACKAGE_URL="https://github.com/KeatonShawhan/KeysightTestAutomation/raw/refs/heads/main/Runner.1.13.0-alpha.84.1+b4b4b421.1203-enable-more-runners-on-a-.Linux.arm64.TapPackage"

# Function to simulate running a test plan and logging data
function run_test_plan() {
  local runner_id=$1
  local test_plan=$2
  local output_file="runner_${runner_id}_metrics.log"
  
  echo "[INFO] Runner #$runner_id executing test plan: $test_plan"
  
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

# Function to check if a port is available
function is_port_available() {
  local port=$1
  nc -z localhost "$port" 2>/dev/null
  return $?
}

# Function to start runners
function start_runners() {
  local num_runners="$1"
  local current_port="$STARTING_PORT"

  for (( i=1; i<=num_runners; i++ )); do
    # Check if the current port is available
    while ! is_port_available "$current_port"; do
      echo "[ERROR] Port $current_port is already in use. Trying next port..."
      ((current_port++))
      if (( current_port > MAX_PORT )); then
        echo "[ERROR] No more ports available to start runners."
        exit 1
      fi
    done

    echo "[INFO] Setting up Runner #$i on port $current_port..."

    # Create a fresh folder for the runner
    local runner_folder="$HOME/runner_$i"
    rm -rf "$runner_folder" 2>/dev/null || true
    mkdir -p "$runner_folder"
    cd "$runner_folder"

    # Download & install base OpenTAP
    echo "[INFO] Downloading base OpenTAP from $OPENTAP_BASE_DOWNLOAD ..."
    curl -sSL -o opentap.zip "$OPENTAP_BASE_DOWNLOAD"
    unzip -q opentap.zip -d ./
    rm opentap.zip
    chmod +x ./tap

    # Install the custom Runner package
    echo "[INFO] Downloading custom Runner from $RUNNER_PACKAGE_URL ..."
    curl -sSL -o custom_runner.tap_package "$RUNNER_PACKAGE_URL"
    echo "[INFO] Installing the custom Runner TapPackage..."
    ./tap package install custom_runner.tap_package >/dev/null 2>&1
    rm custom_runner.tap_package

    # Register the Runner
    echo "[INFO] Registering the Runner with token..."
    ./tap runner register --url "$TAP_URL" --registrationToken "$REGISTRATION_TOKEN" >/dev/null 2>&1

    # Start the runner
    echo "[INFO] Starting Runner #$i on port $current_port..."
    run_test_plan "$i" "$TEST_PLAN" &  # Start the runner in the background
    ((current_port++))  # Move to the next port for the next runner
  done
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

# Start runners
start_runners "$N"

# Wait for all background runners to finish
wait

# Collect and compare performance metrics
collect_metrics
