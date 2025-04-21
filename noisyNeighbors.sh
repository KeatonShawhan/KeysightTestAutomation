#!/usr/bin/env bash
set -e

# resolve script directory, load metric helpers and runner logic
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/metric_tools.sh"

# Source runnerScript.sh for runner management
RUNNER_SCRIPT="${SCRIPT_DIR}/runnerScript.sh"
if [[ ! -f "$RUNNER_SCRIPT" ]]; then
  echo "[ERROR] runnerScript.sh not found at '$RUNNER_SCRIPT'"
  exit 1
fi
# shellcheck source=/dev/null
source "$RUNNER_SCRIPT"

# Set up where logs will go
METRICS_DIR="${SCRIPT_DIR}/metrics"
mkdir -p "$METRICS_DIR"

# Create a timestamped folder for this run
RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SESSION_FOLDER="${METRICS_DIR}/noisyNeighbors_${RUN_TIMESTAMP}"
mkdir -p "$SESSION_FOLDER"

# --- CONFIGURATION ---
STARTING_PORT=20110
MAX_RUNNERS=97
TAP_URL="https://test-automation.pw.keysight.com"

# Function to check if runners directories exist
function check_runners_exist() {
  local needed=$1
  local count=0
  for i in $(seq 1 "$MAX_RUNNERS"); do
    [[ -d "$HOME/runner_$i" ]] && count=$((count+1))
  done
  if (( count < needed )); then
    echo "[ERROR] Not enough runners found. Found $count, but need $needed."
    echo "[INFO] Please run the runnerScript.sh to create more runners."
    exit 1
  fi
  echo "[INFO] Found $count runners, sufficient for testing."
}

# Function to verify the test plan exists
function verify_test_plan() {
  local plan="$1"
  local path="${SCRIPT_DIR}/${plan}"
  if [[ ! -f "$path" ]]; then
    echo "[ERROR] Test plan not found: $path"
    exit 1
  fi
  echo "[INFO] Found test plan: $path"
}

# Function to run a test plan on a specific runner
function run_test_plan() {
  local runner_id=$1
  local test_plan=$2
  local is_baseline=$3
  local runner_dir="$HOME/runner_${runner_id}"
  local test_plan_path="${SCRIPT_DIR}/${test_plan}"
  local output_log="${SESSION_FOLDER}/runner_${runner_id}_output.log"
  local metrics_log="${SESSION_FOLDER}/runner_${runner_id}_metrics.log"

  echo "[INFO] Runner #$runner_id starting test plan: $test_plan"
  [[ ! -d "$runner_dir" ]] && { echo "[ERROR] $runner_dir not found."; return 1; }
  cd "$runner_dir" || return 1

  local start_ts=$(date +%s.%N)
  if [[ "$is_baseline" == true ]]; then
    ./tap run "$test_plan_path" 2>&1 | tee "$output_log"
  else
    ./tap run "$test_plan_path" > "$output_log" 2>&1
  fi
  local end_ts=$(date +%s.%N)

  local runtime=$(awk -v s="$start_ts" -v e="$end_ts" 'BEGIN{printf "%.3f", e-s}')
  echo "runner_id=$runner_id,start=$start_ts,end=$end_ts,runtime=$runtime" > "$metrics_log"
  echo "[INFO] Runner #$runner_id completed in $runtime seconds"
  cd - &>/dev/null
}

# Function to generate summary report
function generate_summary() {
  local plan=$1
  local total=$2
  local baseline=$3
  local sumfile="${SESSION_FOLDER}/summary.txt"
  {
    echo "Noisy Neighbors Test Summary"
    echo "============================="
    echo "Plan: $plan"
    echo "Runners: $total"
    echo "Baseline runtime: $baseline s"
    echo ""
    echo "Concurrent Runtimes:"
    local sum=0 count=0 min=1e9 max=0
    for ((i=2;i<=total;i++)); do
      local f="${SESSION_FOLDER}/runner_${i}_metrics.log"
      [[ -f "$f" ]] || { echo "Runner #$i: missing"; continue; }
      local r=$(grep -oP 'runtime=\K[0-9.]+' "$f")
      echo "Runner #$i: $r s"
      sum=$(awk "BEGIN{print $sum+$r}")
      ((count++))
      (( $(awk "BEGIN{print $r<$min}") )) && min=$r
      (( $(awk "BEGIN{print $r>$max}") )) && max=$r
    done
    echo ""
    if (( count>0 )); then
      local avg=$(awk "BEGIN{print $sum/$count}")
      local impact=$(awk "BEGIN{print ($avg-$baseline)/$baseline*100}")
      echo "Average: $avg s"
      echo "Min: $min s"
      echo "Max: $max s"
      echo "Impact: $impact%"
    fi
  } > "$sumfile"
  echo "[INFO] Summary at: $sumfile"
}

# Main
clear
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <number_of_runners> <registration_token>"
  exit 1
fi
N=$1
REG=$2
if ((N<2)); then echo "Need >=2 runners"; exit 1; fi

# Ensure runners exist (or create them)
echo "[INFO] Ensuring $N runners are present..."
start_runners "$N" "$REG"
check_runners_exist "$N"

# Prompt and verify plan
read -p "Test plan name: " PLAN
verify_test_plan "$PLAN"

# Begin metrics
start_metrics "$SESSION_FOLDER"
# Baseline
echo "--- Baseline (Runner 1) ---"
run_test_plan 1 "$PLAN" true
BASE=$(grep -oP 'runtime=\K[0-9.]+' "${SESSION_FOLDER}/runner_1_metrics.log")
# Concurrent
echo "--- Concurrent (${N}-1 runners) ---"
declare -a PIDS=()
for ((i=2;i<=N;i++)); do
  (run_test_plan $i "$PLAN" false)&
  PIDS+=($!)
done
# Wait
for pid in "${PIDS[@]}"; do wait "$pid"; done
# Finish metrics
kill_metrics "$SESSION_FOLDER"
# Summaries
generate_summary "$PLAN" "$N" "$BASE"
analyze_metrics "$SESSION_FOLDER"

# Cleanup
stop_runners

echo "All done. Logs at: $SESSION_FOLDER"
