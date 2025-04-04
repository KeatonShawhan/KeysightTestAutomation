#!/usr/bin/env bash
#
# active_lab.sh
#
# Spins up a baseline number of OpenTAP runners, then randomly
# adds extra runners (up to a maximum) on random 15-30s intervals,
# runs a given .TapFile in parallel on *all* runners, tears down the extras,
# repeats for exactly 3 cycles, and finally tears down all runners.
#
# IMPORTANT: The test plan path is resolved relative to this script's directory,
# so the .TapFile does NOT need to be located in each runner's folder.
#
# Usage:
#   ./active_lab.sh <min_runners> <max_runners> <test_plan_path> <registration_token>
#
# Example:
#   ./active_lab.sh 2 5 MyPlan.TapPlan <myRegToken>
#
# Requirements:
#   - runnerScript.sh in the same directory
#   - .NET runtime, expect, ss, unzip, curl (same as runnerScript.sh)
#   - The specified test plan must be a valid .TapFile
#

#############################################
#             CONFIG & GLOBALS             #
#############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
RUNNER_SCRIPT="${SCRIPT_DIR}/runnerScript.sh"   # Adjust if needed

METRICS_DIR="${SCRIPT_DIR}/metrics"
mkdir -p "${METRICS_DIR}"

# The base ports used by runnerScript.sh
STARTING_PORT=20110
MAX_RUNNERS=100  # runnerScript.sh's upper limit

#############################################
#        UTILITY & HELPER FUNCTIONS        #
#############################################

usage() {
  echo "Usage:"
  echo "  $0 <min_runners> <max_runners> <test_plan_path> <registration_token>"
  exit 1
}

# Check if a command exists
check_command_exists() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] '$cmd' is not installed or not in PATH."
    return 1
  fi
  return 0
}

# Ensure we have the same dependencies as runnerScript.sh
check_dependencies() {
  local missing=0
  for cmd in dotnet expect ss unzip curl; do
    check_command_exists "$cmd" || missing=1
  done
  if (( missing )); then
    echo "[ERROR] Missing required commands. Exiting."
    exit 1
  fi
}

# Run a test plan (.TapFile) on the specified runner
# Logs to metrics/runner_<id>_cycle_<cycle>_output.log and metrics file
run_test_plan() {
  local runner_id="$1"
  local cycle_number="$2"
  local test_plan_path="$3"  # This should already be absolute

  local runner_folder="$HOME/runner_${runner_id}"
  local output_file="${METRICS_DIR}/runner_${runner_id}_cycle_${cycle_number}_output.log"
  local metrics_file="${METRICS_DIR}/runner_${runner_id}_cycle_${cycle_number}_metrics.log"

  if [[ ! -d "$runner_folder" ]]; then
    echo "[ERROR] (Cycle $cycle_number) Runner directory not found: $runner_folder"
    return 1
  fi

  local start_ts end_ts
  start_ts=$(date +%s.%N)

  # Enter the runner folder to run the local ./tap
  cd "$runner_folder" || return 1

  echo "[INFO] (Cycle $cycle_number) Runner #$runner_id starting test plan: $test_plan_path"
  # Because test_plan_path is absolute (or guaranteed from script dir),
  # we'll run it from here but the file is actually in the script's directory.
  if ! ./tap run "$test_plan_path" &> "$output_file"; then
    echo "[ERROR] (Cycle $cycle_number) Runner #$runner_id had an error running $test_plan_path"
  fi

  end_ts=$(date +%s.%N)
  local duration
  duration=$(awk -v start="$start_ts" -v end="$end_ts" 'BEGIN{printf "%.3f", (end - start)}')

  # Store metric line
  echo "runner_id=$runner_id,cycle=$cycle_number,start=$start_ts,end=$end_ts,runtime=$duration" > "$metrics_file"

  # Return to script dir
  cd "$SCRIPT_DIR" || true
  echo "[INFO] (Cycle $cycle_number) Runner #$runner_id completed in ${duration}s"
}

# Use 'expect' to gracefully unregister a runner on the given port
auto_unregister() {
  local port="$1"
  /usr/bin/expect <<EOF
  set timeout 30
  spawn env OPENTAP_RUNNER_SERVER_PORT="${port}" ./tap runner unregister
  expect {
    -re "Selection.*" {
      send "0\r"
      exp_continue
    }
    eof
  }
EOF
  sleep 2
}

# Remove a specific runner folder by index (unregister + rm)
remove_runner() {
  local runner_id="$1"
  local runner_folder="$HOME/runner_${runner_id}"
  local runner_port=$((STARTING_PORT + runner_id - 1))

  if [[ -d "$runner_folder" ]]; then
    echo "[INFO] Stopping/unregistering runner #$runner_id (port $runner_port)"
    cd "$runner_folder" || return

    if [[ -x ./tap ]]; then
      auto_unregister "$runner_port"
    fi

    cd ~
    rm -rf "$runner_folder"
    echo "[INFO] Removed $runner_folder"
  fi
}

#############################################
#              MAIN SCRIPT LOGIC           #
#############################################

# 1) Argument check
if [[ $# -ne 4 ]]; then
  usage
fi

MIN_RUNNERS="$1"
MAX_RUNNERS_PARAM="$2"
USER_TEST_PLAN="$3"
REG_TOKEN="$4"

# Validate input
if (( MIN_RUNNERS < 1 )); then
  echo "[ERROR] Minimum runners must be >= 1."
  exit 1
fi

if (( MAX_RUNNERS_PARAM > 30 )); then
  echo "[ERROR] The maximum runners parameter must not exceed 30."
  exit 1
fi

if (( MAX_RUNNERS_PARAM < MIN_RUNNERS )); then
  echo "[ERROR] The maximum runners cannot be smaller than the minimum."
  exit 1
fi

# 2) Dependencies
check_dependencies

# 3) Resolve the test plan path relative to script's directory if needed
#    so we end up with an absolute path that doesn't depend on the runner folder.
ABS_TEST_PLAN=""
if [[ -f "$USER_TEST_PLAN" ]]; then
  # If user gave an absolute path or a relative path from current shell
  ABS_TEST_PLAN="$(cd "$(dirname "$USER_TEST_PLAN")"; pwd)/$(basename "$USER_TEST_PLAN")"
elif [[ -f "${SCRIPT_DIR}/${USER_TEST_PLAN}" ]]; then
  # If the file exists relative to the script's directory
  ABS_TEST_PLAN="$(cd "$SCRIPT_DIR"; pwd)/$(basename "$USER_TEST_PLAN")"
else
  echo "[ERROR] Test plan not found at '$USER_TEST_PLAN' nor in '$SCRIPT_DIR/$USER_TEST_PLAN'"
  exit 1
fi

# 4) Stop all existing runners first (clean slate)
echo "----------------------------------------------------"
echo "[INFO] Stopping any existing runners..."
if [[ -f "$RUNNER_SCRIPT" ]]; then
  "$RUNNER_SCRIPT" stop
else
  echo "[ERROR] runnerScript.sh not found at '$RUNNER_SCRIPT'. Adjust the path."
  exit 1
fi

# 5) Spin up the baseline (min) runners
echo "----------------------------------------------------"
echo "[INFO] Spinning up the baseline ($MIN_RUNNERS) runners..."
"$RUNNER_SCRIPT" start "$MIN_RUNNERS" "$REG_TOKEN"

echo "[INFO] Baseline is up. We will do 3 test cycles with random expansions."

# Number of cycles we want
CYCLES=3

for cycle in $(seq 1 $CYCLES); do
  echo "============================================================"
  echo "[INFO] Starting cycle $cycle of $CYCLES"

  # Random wait [15..30] seconds before spinning extra
  WAIT1=$((15 + RANDOM % 16))
  echo "[INFO] Waiting $WAIT1 seconds before spinning up extra runners..."
  sleep "$WAIT1"

  # Determine how many extras we can add
  local_max_extras=$((MAX_RUNNERS_PARAM - MIN_RUNNERS))
  if (( local_max_extras <= 0 )); then
    echo "[WARN] min_runners == max_runners, so no extras can be added."
    EXTRA=0
  else
    # random number in [1..local_max_extras]
    EXTRA=$((1 + RANDOM % local_max_extras))
  fi

  if (( EXTRA > 0 )); then
    echo "[INFO] Spinning up $EXTRA extra runners (cycle $cycle)."
    "$RUNNER_SCRIPT" start "$EXTRA" "$REG_TOKEN"
  else
    echo "[INFO] No extra runners this cycle."
  fi

  # Now run the test plan on ALL (min + extra) runners CONCURRENTLY
  CURRENT_TOTAL=$((MIN_RUNNERS + EXTRA))
  echo "----------------------------------------------------"
  echo "[INFO] Running test plan (in parallel) on $CURRENT_TOTAL runners..."
  
  declare -a RUNNER_PIDS=()
  for runner_id in $(seq 1 "$CURRENT_TOTAL"); do
    # We fork each runner's run in the background
    ( run_test_plan "$runner_id" "$cycle" "$ABS_TEST_PLAN" ) &
    RUNNER_PIDS+=($!)
  done

  # Wait for all runner processes to complete
  echo "[INFO] Waiting for $CURRENT_TOTAL runners to finish..."
  for pid in "${RUNNER_PIDS[@]}"; do
    wait "$pid"
  done
  echo "[INFO] All runners done for cycle $cycle."

  # Spin the extras back down (if any)
  if (( EXTRA > 0 )); then
    echo "----------------------------------------------------"
    echo "[INFO] Removing the $EXTRA extra runners, returning to baseline of $MIN_RUNNERS..."
    # The new extra runners occupy the highest runner indices. We find the existing max index:
    highest_index=0
    for i in $(seq 1 100); do
      if [[ -d "$HOME/runner_$i" ]]; then
        highest_index="$i"
      fi
    done
    # Now remove exactly $EXTRA from the top
    end_index="$highest_index"
    start_index=$((highest_index - EXTRA + 1))

    if (( start_index < 1 )); then
      echo "[ERROR] Calculated invalid runner range to remove: $start_index..$end_index"
      exit 1
    fi

    for r in $(seq "$end_index" -1 "$start_index"); do
      remove_runner "$r"
    done
  fi

  # Random wait [15..30] seconds before next cycle
  if (( cycle < CYCLES )); then
    WAIT2=$((15 + RANDOM % 16))
    echo "[INFO] Cycle $cycle complete. Waiting $WAIT2 seconds before next cycle..."
    sleep "$WAIT2"
  else
    echo "[INFO] Final cycle ($cycle) complete!"
  fi

done

echo "============================================================"
echo "[INFO] All 3 cycles finished. Now spinning down all runners."
echo "[INFO] Calling runnerScript.sh stop..."
"$RUNNER_SCRIPT" stop

echo "[INFO] All runners have been stopped and unregistered."
echo "[INFO] Metrics and outputs are in '${METRICS_DIR}'."
echo "[INFO] Done."

