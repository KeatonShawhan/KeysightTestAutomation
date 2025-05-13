#!/usr/bin/env bash
#
# 9am_monday.sh
#
# A "9AM Monday" scenario: we spin up N runners, wait 5 seconds, then
# ramp up test plans in waves. Each wave uses a larger subset of runners,
# while the delay between waves gets shorter. The sets of runners are picked
# randomly so each wave might have different IDs. 
#
# Usage:
#   ./9am_monday.sh <runners> <test_plan_path> <registration_token>
#
# Example:
#   ./9am_monday.sh 10 MyPlan.TapPlan <myRegToken>
#
# Requirements:
#   - runnerScript.sh in the same directory
#   - .NET runtime, expect, ss, unzip, curl, etc.
#   - The specified test plan must be a valid .TapFile
#   - Each wave's "subset" can be tailored to your desired wave pattern
#

#############################################
#             CONFIG & GLOBALS             #
#############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
RUNNER_SCRIPT="${SCRIPT_DIR}/runnerScript.sh"


METRICS_DIR="${SCRIPT_DIR}/metrics"
mkdir -p "${METRICS_DIR}"

#############################################
#        UTILITY & HELPER FUNCTIONS        #
#############################################

usage() {
  echo "Usage:"
  echo "  $0 <runners> <test_plan_path> <registration_token>"
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

# Run a test plan on a specific runner (parallel-friendly).
# Logs go to the run-specific folder for this scenario.
run_test_plan() {
  local runner_id="$1"
  local wave_label="$2"        # e.g., wave1, wave2, wave3
  local test_plan_path="$3"    # absolute or script-relative
  local session_folder="$4"

  local runner_folder="$HOME/runner_${runner_id}"
  local output_file="${session_folder}/runner_${runner_id}_${wave_label}_output.log"
  local metrics_file="${session_folder}/runner_${runner_id}_${wave_label}_metrics.log"

  if [[ ! -d "$runner_folder" ]]; then
    echo "[ERROR] Runner directory not found: $runner_folder"
    return 1
  fi

  local start_ts=$(date +%s.%N)

  cd "$runner_folder" || return 1

  echo "[INFO] Runner #$runner_id in ${wave_label} starting test plan: $test_plan_path"
  if ! ./tap run "$test_plan_path" &> "$output_file"; then
    echo "[ERROR] Runner #$runner_id had an error in wave ${wave_label}"
  fi

  local end_ts=$(date +%s.%N)
  local duration
  duration=$(awk -v start="$start_ts" -v end="$end_ts" 'BEGIN{printf "%.3f", (end - start)}')

  echo "runner_id=$runner_id,wave=$wave_label,start=$start_ts,end=$end_ts,runtime=$duration" > "$metrics_file"

  cd "$SCRIPT_DIR" || true
  echo "[INFO] Runner #$runner_id in ${wave_label} completed in ${duration}s"
}

# Stop all runners
stop_all_runners() {
  if [[ -f "$RUNNER_SCRIPT" ]]; then
    "$RUNNER_SCRIPT" stop
  else
    echo "[ERROR] runnerScript.sh not found at '$RUNNER_SCRIPT'"
  fi
}

#############################################
#              MAIN SCRIPT LOGIC           #
#############################################

# 1) Argument check
if [[ $# -ne 3 ]]; then
  usage
fi

NUM_RUNNERS="$1"
USER_TEST_PLAN="$2"
REG_TOKEN="$3"

if (( NUM_RUNNERS < 1 )); then
  echo "[ERROR] Number of runners must be >=1."
  exit 1
fi

# 2) Check dependencies
check_dependencies

# 3) Resolve test plan path relative to the script directory if needed
ABS_TEST_PLAN=""
if [[ -f "$USER_TEST_PLAN" ]]; then
  # If user gave an absolute path or a relative path from the current shell
  ABS_TEST_PLAN="$(cd "$(dirname "$USER_TEST_PLAN")"; pwd)/$(basename "$USER_TEST_PLAN")"
elif [[ -f "${SCRIPT_DIR}/${USER_TEST_PLAN}" ]]; then
  # If the file exists in the script directory
  ABS_TEST_PLAN="$(cd "$SCRIPT_DIR"; pwd)/$(basename "$USER_TEST_PLAN")"
elif [[ -f "${SCRIPT_DIR}/../../taprunner/${USER_TEST_PLAN}" ]]; then
  # Fallback: if test plan is in taprunner/ relative to repo root
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
SESSION_FOLDER="${METRICS_DIR}/9amMonday_${RUN_TIMESTAMP}"
mkdir -p "$SESSION_FOLDER"

# Export & load metrics tooling
export METRICS_DIR="$SESSION_FOLDER"
source "${SCRIPT_DIR}/metric_tools.sh"

# start metrics
start_metrics "$SESSION_FOLDER"

echo "----------------------------------------------------"
echo "[INFO] 9AM Monday scenario. Logs in: $SESSION_FOLDER"

# 5) Stop all existing runners
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

# 7) A short initial pause
echo "[INFO] Runners spun up. Waiting 5 seconds before wave ramp-up..."
sleep 5

# -------------------------------------------------------------------------
#  WAVE LOGIC
#
#  We'll do a simple 3-wave example:
#     - Wave 1: ~20% of runners
#     - Wave 2: ~30% of runners
#     - Wave 3: ~50% of runners
#
#  We pick random subsets so each wave might have unique runner IDs.
#  The intervals between waves get smaller (1s -> 0.5s).
#
#  You can easily tweak wave counts, wave sizes, and wait durations
#  to match your real "9AM Monday" ramp pattern.
# -------------------------------------------------------------------------

# Shuffle runner IDs 1..N into an array to get random subsets
# (This is a basic Fisher-Yates shuffle for demonstration)
all_runners=($(seq 1 "$NUM_RUNNERS"))
for (( i=${#all_runners[@]}-1; i>0; i-- )); do
  j=$((RANDOM % (i+1)))
  # swap
  temp="${all_runners[i]}"
  all_runners[i]="${all_runners[j]}"
  all_runners[j]="$temp"
done

# We'll define approximate wave sizes with random +/- 2
wave1_count=$(( (NUM_RUNNERS*20/100) + (RANDOM%5 - 2) ))
if (( wave1_count < 1 )); then wave1_count=1; fi
if (( wave1_count >= NUM_RUNNERS )); then wave1_count=$((NUM_RUNNERS - 1)); fi

wave2_count=$(( (NUM_RUNNERS*30/100) + (RANDOM%5 - 2) ))
if (( wave2_count < 1 )); then wave2_count=1; fi
if (( wave1_count + wave2_count >= NUM_RUNNERS )); then
  wave2_count=$((NUM_RUNNERS - wave1_count - 1))
fi
if (( wave2_count < 0 )); then
  wave2_count=0
fi

wave3_count=$(( NUM_RUNNERS - wave1_count - wave2_count ))
if (( wave3_count < 0 )); then
  wave3_count=0
fi

echo "[INFO] Calculated wave sizes: wave1=$wave1_count, wave2=$wave2_count, wave3=$wave3_count"

# Extract subsets from the shuffled array
wave1_ids=("${all_runners[@]:0:wave1_count}")
wave2_ids=("${all_runners[@]:wave1_count:wave2_count}")
wave3_ids=("${all_runners[@]:wave1_count+wave2_count:wave3_count}")

# We'll store all PIDs for the test runs here so we can wait on them at the end
declare -a TEST_RUN_PIDS=()

#############################################
#    WAVE 1
#############################################
if (( wave1_count > 0 )); then
  echo "----------------------------------------------------"
  echo "[INFO] Wave1: Starting ${wave1_count} runners..."
  for runner_id in "${wave1_ids[@]}"; do
    ( run_test_plan "$runner_id" "wave1" "$ABS_TEST_PLAN" "$SESSION_FOLDER" ) &
    TEST_RUN_PIDS+=($!)
  done

  echo "[INFO] Wave1 started. Sleeping 1 second before Wave2..."
  sleep 1
fi

#############################################
#    WAVE 2
#############################################
if (( wave2_count > 0 )); then
  echo "----------------------------------------------------"
  echo "[INFO] Wave2: Starting ${wave2_count} runners..."
  for runner_id in "${wave2_ids[@]}"; do
    ( run_test_plan "$runner_id" "wave2" "$ABS_TEST_PLAN" "$SESSION_FOLDER" ) &
    TEST_RUN_PIDS+=($!)
  done

  echo "[INFO] Wave2 started. Sleeping 0.5 seconds before Wave3..."
  sleep 0.5
fi

#############################################
#    WAVE 3
#############################################
if (( wave3_count > 0 )); then
  echo "----------------------------------------------------"
  echo "[INFO] Wave3: Starting ${wave3_count} runners..."
  for runner_id in "${wave3_ids[@]}"; do
    ( run_test_plan "$runner_id" "wave3" "$ABS_TEST_PLAN" "$SESSION_FOLDER" ) &
    TEST_RUN_PIDS+=($!)
  done

  echo "[INFO] Wave3 started. Sleeping 0.25 seconds after final wave..."
  sleep 0.25
fi

# 8) Now all waves have been triggered, possibly overlapping. We wait for
#    all test-plan processes to finish before spinning down the runners.
echo "----------------------------------------------------"
echo "[INFO] Waiting for all wave processes to complete..."
for pid in "${TEST_RUN_PIDS[@]}"; do
  wait "$pid"
done

echo "[INFO] All wave-based test runs have completed."

# 9) Stop all runners
echo "----------------------------------------------------"
echo "[INFO] Tearing down all runners..."
stop_all_runners

generate_charts "$SESSION_FOLDER"

kill_metrics "$SESSION_FOLDER"

echo "[INFO] Scenario complete! Logs and metrics in: $SESSION_FOLDER"

