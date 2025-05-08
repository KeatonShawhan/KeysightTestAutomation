#!/usr/bin/env bash
#
# 9am_monday_login.sh
#
# A "9AM Monday" scenario: we spin up N runners, wait 5 seconds, then
# ramp up test plans in waves. Each wave uses a larger subset of runners,
# while the delay between waves gets shorter. The sets of runners are picked
# randomly so each wave might have different IDs. 
#
# Usage:
#   ./9am_monday.sh <runners> <test_plan_path> <registration_token> [simulate_logins] [login_retries]
#
# Example:
#   ./9am_monday.sh 10 MyPlan.TapPlan <myRegToken>
#   ./9am_monday.sh 10 MyPlan.TapPlan <myRegToken> true
#   ./9am_monday.sh 10 MyPlan.TapPlan <myRegToken> true 3
#
# Requirements:
#   - runnerScript.sh in the parent directory
#   - .NET runtime, expect, ss, unzip, curl, etc.
#   - The specified test plan must be a valid .TapFile
#   - Cypress installed (only if simulate_logins=true)
#   - Each wave's "subset" can be tailored to your desired wave pattern
#

#############################################
#             CONFIG & GLOBALS             #
#############################################

# Path to the current script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Path to the parent directory (KeysightTestAutomation)
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# Path to the auth service directory
AUTH_SERVICE_DIR="${PARENT_DIR}/ks8500-auth-service"

# Path to the runner script
RUNNER_SCRIPT="${SCRIPT_DIR}/runnerScript.sh"

METRICS_DIR="${SCRIPT_DIR}/metrics"
mkdir -p "${METRICS_DIR}"

# Default login simulation settings
DEFAULT_SIMULATE_LOGINS="false"
DEFAULT_LOGIN_RETRIES=2

#############################################
#        UTILITY & HELPER FUNCTIONS        #
#############################################

usage() {
  echo "Usage:"
  echo "  $0 <runners> <test_plan_path> <registration_token> [simulate_logins] [login_retries]"
  echo "  simulate_logins: 'true' or 'false' (default: false)"
  echo "  login_retries: number of retries for failed login simulations (default: 2)"
  echo "  (When simulate_logins is true, one login will be simulated per runner)"
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
  local simulate_logins="$1"
  
  # Always required commands
  for cmd in dotnet expect ss unzip curl; do
    check_command_exists "$cmd" || missing=1
  done
  
  # Only check for npx if simulating logins
  if [[ "$simulate_logins" == "true" ]]; then
    check_command_exists "npx" || missing=1
  fi
  
  if (( missing )); then
    echo "[ERROR] Missing one or more required commands. Exiting."
    exit 1
  fi
  return 0
}

# Try to run a Cypress login with retries
run_cypress_login() {
  local login_id="$1"
  local log_file="$2"
  local max_retries="$3"
  local retry=0
  local success=false
  
  while [[ "$retry" -le "$max_retries" && "$success" = "false" ]]; do
    if [[ "$retry" -gt 0 ]]; then
      echo "[INFO] Login simulation #$login_id - Retry attempt $retry of $max_retries"
    fi
    
    # Run Cypress from the auth service directory
    cd "$AUTH_SERVICE_DIR" && npx cypress run --spec cypress/tests/auth.spec.js --env environment=production,login_email=?,login_username=?,login_password=? > "$log_file" 2>&1
    
    # Check the exit code
    if [[ $? -eq 0 ]]; then
      echo "[INFO] Login simulation #$login_id successful on attempt $((retry+1))"
      success=true
      break
    else
      echo "[WARN] Login simulation #$login_id failed on attempt $((retry+1))"
      retry=$((retry+1))
      # Add a small delay before retrying
      sleep 2
    fi
  done
  
  if [[ "$success" = "false" ]]; then
    echo "[ERROR] Login simulation #$login_id failed after $max_retries retries"
    return 1
  fi
  
  return 0
}

# Simulate multiple users logging in
simulate_logins() {
  local num_logins="$1"
  local session_folder="$2"
  local max_retries="$3"
  
  echo "[INFO] Simulating $num_logins users logging in simultaneously (one per runner), with up to $max_retries retries..."
  
  # Create a directory for login simulation logs
  local login_logs_dir="${session_folder}/login_logs"
  mkdir -p "$login_logs_dir"
  
  # Run multiple login simulations in parallel
  local pids=()
  local log_files=()
  for (( i=1; i<=$num_logins; i++ )); do
    local log_file="${login_logs_dir}/login_${i}.log"
    log_files+=("$log_file")
    
    # Run Cypress in the background with retry logic
    (
      echo "[INFO] Starting login simulation #$i"
      run_cypress_login "$i" "$log_file" "$max_retries"
      echo "[INFO] Login simulation #$i process completed"
    ) &
    pids+=($!)
  done
  
  # Wait for all login simulations to complete
  echo "[INFO] Waiting for all login simulations to complete (with retries if needed)..."
  local failed=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      failed=$((failed+1))
    fi
  done
  
  if [[ "$failed" -gt 0 ]]; then
    echo "[WARN] $failed out of $num_logins login simulations failed after all retries"
  else
    echo "[INFO] All login simulations completed successfully."
  fi
  
  # Summarize results
  echo "----------------------------------------------------"
  echo "[INFO] Login simulation summary:"
  echo "  - Total login attempts: $num_logins"
  echo "  - Successful logins: $((num_logins-failed))"
  echo "  - Failed logins: $failed"
  echo "  - Logs are available in: $login_logs_dir"
  echo "----------------------------------------------------"
  
  return $failed
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
if [[ $# -lt 3 || $# -gt 5 ]]; then
  usage
fi

NUM_RUNNERS="$1"
USER_TEST_PLAN="$2"
REG_TOKEN="$3"
SIMULATE_LOGINS="${4:-$DEFAULT_SIMULATE_LOGINS}"
LOGIN_RETRIES="${5:-$DEFAULT_LOGIN_RETRIES}"

if (( NUM_RUNNERS < 1 )); then
  echo "[ERROR] Number of runners must be >=1."
  exit 1
fi

# 2) Check dependencies
check_dependencies "$SIMULATE_LOGINS"

# 3) Resolve test plan path relative to the script directory or parent directory if needed
ABS_TEST_PLAN=""
if [[ -f "$USER_TEST_PLAN" ]]; then
  # If user gave an absolute path or a relative path from the current shell
  ABS_TEST_PLAN="$(cd "$(dirname "$USER_TEST_PLAN")"; pwd)/$(basename "$USER_TEST_PLAN")"
elif [[ -f "${SCRIPT_DIR}/${USER_TEST_PLAN}" ]]; then
  # If the file exists in the script directory
  ABS_TEST_PLAN="$(cd "$SCRIPT_DIR"; pwd)/$(basename "$USER_TEST_PLAN")"
elif [[ -f "${PARENT_DIR}/${USER_TEST_PLAN}" ]]; then
  # If the file exists in the parent directory (KeysightTestAutomation)
  ABS_TEST_PLAN="$(cd "$PARENT_DIR"; pwd)/$(basename "$USER_TEST_PLAN")"
else
  echo "[ERROR] Test plan not found at '$USER_TEST_PLAN' nor '${SCRIPT_DIR}/${USER_TEST_PLAN}' nor '${PARENT_DIR}/${USER_TEST_PLAN}'"
  exit 1
fi

# 4) Create a dated folder for logs/metrics
RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SESSION_FOLDER="${METRICS_DIR}/${RUN_TIMESTAMP}"
mkdir -p "$SESSION_FOLDER"

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
echo "[INFO] Runners spun up. Waiting 5 seconds before continuing..."
sleep 5

# 8) Simulate login traffic if requested - MOVED HERE from earlier in the flow
if [[ "$SIMULATE_LOGINS" == "true" ]]; then
  echo "[INFO] Simulating login traffic with $NUM_RUNNERS concurrent logins (one per runner)..."
  simulate_logins "$NUM_RUNNERS" "$SESSION_FOLDER" "$LOGIN_RETRIES"
  
  # Check if too many login simulations failed
  login_failures=$?
  max_allowed_failures=$((NUM_RUNNERS / 2))
  if [[ "$login_failures" -gt "$max_allowed_failures" ]]; then
    echo "[ERROR] Too many login simulations failed ($login_failures). Cannot proceed with test execution."
    stop_all_runners
    exit 1
  elif [[ "$login_failures" -gt 0 ]]; then
    echo "[WARN] Some login simulations failed ($login_failures), but we can still proceed with test execution."
  fi
else
  echo "[INFO] Login simulation disabled. Proceeding with test execution..."
fi

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

# 9) Now all waves have been triggered, possibly overlapping. We wait for
#    all test-plan processes to finish before spinning down the runners.
echo "----------------------------------------------------"
echo "[INFO] Waiting for all wave processes to complete..."
for pid in "${TEST_RUN_PIDS[@]}"; do
  wait "$pid"
done

echo "[INFO] All wave-based test runs have completed."

# 10) Stop all runners
echo "----------------------------------------------------"
echo "[INFO] Tearing down all runners..."
stop_all_runners

echo "[INFO] Scenario complete! Logs and metrics in: $SESSION_FOLDER"
