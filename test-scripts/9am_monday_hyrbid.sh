#!/usr/bin/env bash
#
#/////////////////IMPORTANT/////////////////////
#
#  **This script is to replace the current 9am monday script when approved**
#
#//////////////////////////////////////////////
#
# 9am_monday.sh
#
# A "9 AM Monday" load-up scenario:
#   • Spin up N runners
#   • (Optional) simulate user log-ins via Cypress
#   • Execute the test plan in three ramp-up waves
#   • Collect metrics, tear everything down
#
# Usage:
#   ./9am_monday.sh <runners> <test_plan_path> <registration_token> [simulate_logins] [login_retries]
#
# Example:
#   ./9am_monday.sh 10 MyPlan.TapPlan <myRegToken>          # classic
#   ./9am_monday.sh 10 MyPlan.TapPlan <myRegToken> true     # with login traffic
#   ./9am_monday.sh 10 MyPlan.TapPlan <myRegToken> true 3   # allow 3 retries / login
#
# Requirements:
#   - runnerScript.sh in the same directory
#   - .NET runtime, expect, ss, unzip, curl
#   - Cypress & Node  (only when simulate_logins=true)
#   - A valid .TapPlan file
#

#############################################
#             CONFIG & GLOBALS             #
#############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." &>/dev/null && pwd)"

RUNNER_SCRIPT="${SCRIPT_DIR}/runnerScript.sh"

METRICS_DIR="${REPO_ROOT}/metrics"
mkdir -p "${METRICS_DIR}"

# ---------- LOGIN-simulation specifics ----------
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
AUTH_SERVICE_DIR="${PARENT_DIR}/ks8500-auth-service"

DEFAULT_SIMULATE_LOGINS="false"
DEFAULT_LOGIN_RETRIES=2
LOGIN_RATE=5   # one login per LOGIN_RATE runners
# ------------------------------------------------

#############################################
#        UTILITY & HELPER FUNCTIONS        #
#############################################

usage() {
  echo "Usage:"
  echo "  $0 <runners> <test_plan_path> <registration_token> [simulate_logins] [login_retries]"
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
  local simulate_logins="$1"
  local missing=0

  for cmd in dotnet expect ss unzip curl; do
    check_command_exists "$cmd" || missing=1
  done

  if [[ "$simulate_logins" == "true" ]]; then
    check_command_exists "npx" || missing=1
  fi

  if (( missing )); then
    echo "[ERROR] Missing one or more required commands. Exiting."
    exit 1
  fi
}

# ---------- LOGIN-simulation helpers ----------

run_cypress_login() {
  local login_id="$1"
  local log_file="$2"
  local max_retries="$3"
  local attempt=0

  while (( attempt <= max_retries )); do
    if (( attempt > 0 )); then
      echo "[INFO] Login #$login_id retry $attempt/$max_retries"
    fi

    ( cd "$AUTH_SERVICE_DIR" && \
      npx cypress run \
        --spec cypress/tests/auth.spec.js \
        --env environment=production,login_email=?,login_username=?,login_password=? \
        &> "$log_file" )

    if [[ $? -eq 0 ]]; then
      echo "[INFO] Login #$login_id succeeded"
      return 0
    fi

    attempt=$(( attempt + 1 ))
    sleep 2
  done

  echo "[ERROR] Login #$login_id failed after $max_retries retries"
  return 1
}

simulate_logins() {
  local num_runners="$1"
  local session_folder="$2"
  local max_retries="$3"

  local num_logins=$(( (num_runners + LOGIN_RATE - 1) / LOGIN_RATE ))
  local login_logs_dir="${session_folder}/login_logs"
  mkdir -p "$login_logs_dir"

  echo "[INFO] Simulating $num_logins logins (≈1 per $LOGIN_RATE runners)"

  local pids=() failures=0
  for (( i=1; i<=num_logins; i++ )); do
    local log_file="${login_logs_dir}/login_${i}.log"
    (
      echo "[INFO] Starting login #$i"
      run_cypress_login "$i" "$log_file" "$max_retries"
    ) &
    pids+=($!)
  done

  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then failures=$((failures+1)); fi
  done

  echo "----------------------------------------------------"
  echo "[INFO] Login summary: success=$((num_logins-failures))  failed=$failures"
  echo "[INFO] Logs in: $login_logs_dir"
  echo "----------------------------------------------------"
  return $failures
}

# ---------- Core test-run helpers ----------

run_test_plan() {  # unchanged from original
  local runner_id="$1" wave_label="$2" test_plan_path="$3" session_folder="$4"

  local runner_folder="$HOME/runner_${runner_id}"
  local output_file="${session_folder}/runner_${runner_id}_${wave_label}_output.log"
  local metrics_file="${session_folder}/runner_${runner_id}_${wave_label}_metrics.log"

  [[ -d "$runner_folder" ]] || { echo "[ERROR] Runner dir $runner_folder missing"; return 1; }

  local start_ts=$(date +%s.%N)
  cd "$runner_folder" || return 1

  echo "[INFO] Runner #$runner_id ($wave_label) starting test plan"
  ./tap run "$test_plan_path" &> "$output_file"
  [[ $? -ne 0 ]] && echo "[ERROR] Runner #$runner_id had an error"

  local end_ts=$(date +%s.%N)
  awk -v s="$start_ts" -v e="$end_ts" 'BEGIN{printf "runner_id=%s,wave=%s,start=%s,end=%s,runtime=%.3f\n",ARGV[1],ARGV[2],s,e,(e-s)}' "$runner_id" "$wave_label" > "$metrics_file"

  cd "$SCRIPT_DIR" || true
  echo "[INFO] Runner #$runner_id ($wave_label) complete"
}

stop_all_runners() {  # unchanged
  [[ -f "$RUNNER_SCRIPT" ]] && "$RUNNER_SCRIPT" stop || echo "[WARN] runnerScript.sh not found"
}

#############################################
#              MAIN SCRIPT                 #
#############################################

(( $# < 3 || $# > 5 )) && usage

NUM_RUNNERS="$1"
USER_TEST_PLAN="$2"
REG_TOKEN="$3"
SIMULATE_LOGINS="${4:-$DEFAULT_SIMULATE_LOGINS}"
LOGIN_RETRIES="${5:-$DEFAULT_LOGIN_RETRIES}"

(( NUM_RUNNERS < 1 )) && { echo "[ERROR] runners must be ≥1"; exit 1; }

check_dependencies "$SIMULATE_LOGINS"

# Resolve test-plan path
if [[ -f "$USER_TEST_PLAN" ]]; then
  ABS_TEST_PLAN="$(cd "$(dirname "$USER_TEST_PLAN")" && pwd)/$(basename "$USER_TEST_PLAN")"
elif [[ -f "${SCRIPT_DIR}/${USER_TEST_PLAN}" ]]; then
  ABS_TEST_PLAN="${SCRIPT_DIR}/$(basename "$USER_TEST_PLAN")"
elif [[ -f "${SCRIPT_DIR}/../../taprunner/${USER_TEST_PLAN}" ]]; then
  ABS_TEST_PLAN="$(cd "${SCRIPT_DIR}/../../taprunner" && pwd)/$(basename "$USER_TEST_PLAN")"
else
  echo "[ERROR] Test plan '$USER_TEST_PLAN' not found"; exit 1
fi

RUN_TS="$(date +%Y%m%d_%H%M%S)"
SESSION_FOLDER="${METRICS_DIR}/9amMonday_${RUN_TS}"
mkdir -p "$SESSION_FOLDER"

# ---- metrics start (original behaviour retained) ----
export METRICS_DIR="$SESSION_FOLDER"
source "${SCRIPT_DIR}/metric_tools.sh"
start_metrics "$SESSION_FOLDER"
# -----------------------------------------------------

echo "----------------------------------------------------"
echo "[INFO] Logs/metrics folder: $SESSION_FOLDER"

echo "[INFO] Stopping pre-existing runners..."
stop_all_runners

echo "[INFO] Spinning up $NUM_RUNNERS runners..."
"$RUNNER_SCRIPT" start "$NUM_RUNNERS" "$REG_TOKEN" || { echo "[ERROR] runnerScript failure"; exit 1; }

echo "[INFO] Runners up. Waiting 5 s..."
sleep 5

# ---------- Optional login traffic ----------
if [[ "$SIMULATE_LOGINS" == "true" ]]; then
  simulate_logins "$NUM_RUNNERS" "$SESSION_FOLDER" "$LOGIN_RETRIES"
  login_failures=$?
  max_allowed=$(( (NUM_RUNNERS + LOGIN_RATE -1) / LOGIN_RATE / 2 ))
  if (( login_failures > max_allowed )); then
    echo "[ERROR] Too many login failures ($login_failures); aborting test run."
    stop_all_runners
    kill_metrics "$SESSION_FOLDER"
    exit 1
  fi
else
  echo "[INFO] Login simulation disabled."
fi
# -------------------------------------------

#################################################################
#                       WAVE EXECUTION                          #
#################################################################

# Random-shuffle runner IDs
all_runners=($(seq 1 "$NUM_RUNNERS"))
for (( i=${#all_runners[@]}-1; i>0; i-- )); do
  j=$((RANDOM % (i+1))); tmp="${all_runners[i]}"; all_runners[i]="${all_runners[j]}"; all_runners[j]="$tmp"
done

wave1=$(( (NUM_RUNNERS*20/100) + (RANDOM%5 - 2) )); (( wave1<1 )) && wave1=1
(( wave1 >= NUM_RUNNERS )) && wave1=$((NUM_RUNNERS-1))
wave2=$(( (NUM_RUNNERS*30/100) + (RANDOM%5 - 2) ))
(( wave2<1 )) && wave2=1
(( wave1+wave2 >= NUM_RUNNERS )) && wave2=$((NUM_RUNNERS-wave1-1))
(( wave2<0 )) && wave2=0
wave3=$(( NUM_RUNNERS-wave1-wave2 )); (( wave3<0 )) && wave3=0

echo "[INFO] Wave sizes  W1=$wave1  W2=$wave2  W3=$wave3"

wave1_ids=("${all_runners[@]:0:wave1}")
wave2_ids=("${all_runners[@]:wave1:wave2}")
wave3_ids=("${all_runners[@]:wave1+wave2:wave3}")

TEST_RUN_PIDS=()

launch_wave () {
  local ids=("$@") label="$1"; shift
  echo "----------------------------------------------------"
  echo "[INFO] $label: launching ${#ids[@]} runners"
  for rid in "${ids[@]}"; do
    ( run_test_plan "$rid" "$label" "$ABS_TEST_PLAN" "$SESSION_FOLDER" ) & TEST_RUN_PIDS+=($!)
  done
}

(( wave1 > 0 )) && { launch_wave "wave1" "${wave1_ids[@]}"; sleep 1; }
(( wave2 > 0 )) && { launch_wave "wave2" "${wave2_ids[@]}"; sleep 0.5; }
(( wave3 > 0 )) && { launch_wave "wave3" "${wave3_ids[@]}"; sleep 0.25; }

echo "----------------------------------------------------"
echo "[INFO] Waiting for all tests to finish..."
for p in "${TEST_RUN_PIDS[@]}"; do wait "$p"; done
echo "[INFO] All test runs complete."

echo "----------------------------------------------------"
echo "[INFO] Tearing down runners..."
stop_all_runners

generate_charts "$SESSION_FOLDER"
kill_metrics "$SESSION_FOLDER"

echo "[INFO] Scenario complete. Artefacts in $SESSION_FOLDER"

