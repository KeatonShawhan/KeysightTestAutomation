#!/usr/bin/env bash
#
# multi_runner.sh
#
# A script to spin up multiple OpenTAP runners on a Raspberry Pi, each bound
# to a unique port. Key features:
#   - Can be called multiple times in a row; it detects existing runner_*
#     folders and continues numbering from the highest index found.
#   - Creates all N requested runners (no more stopping after just one).
#   - Checks each port beforehand to avoid partial installs when a port is busy.
#   - Uses an 'expect' script to gracefully unregister (tap runner unregister)
#     when you do `./multi_runner.sh stop`.
#   - Copies Instruments.xml to each runner's Settings/Bench/Default directory.
#   - Executes Baseline.TapPlan in each runner directory.
#
# Usage:
#   ./multi_runner.sh start <number_of_runners> <registration_token>
#   ./multi_runner.sh stop
#
# Requirements:
#   1) .NET runtime
#   2) 'expect'
#   3) 'ss' (usually in 'iproute2' package) and 'unzip' installed
#   4) Instruments.xml file in the same directory as this script
#   5) Baseline.TapPlan must be available in each runner directory
#
# If a step fails, the script will log an error and exit.
#
# Example:
#   ./multi_runner.sh start 3 <token>  # Creates 3 new runners
#   ./multi_runner.sh start 2 <token>  # Creates 2 more, now 5 total

#############################################
#               CONFIGURATION               #
#############################################

# The valid port range:
STARTING_PORT=20110
MAX_PORT=20220

# Maximum runner folders we will create, total:
MAX_RUNNERS=100

# Where to register the runner:
TAP_URL="https://test-automation.pw.keysight.com"

# Base OpenTAP package (for the 'tap' command):
OPENTAP_BASE_DOWNLOAD="https://packages.opentap.io/4.0/Objects/Packages/OpenTAP?os=Linux&architecture=arm64"

# Custom runner TapPackage URL:
RUNNER_PACKAGE_URL="https://github.com/KeatonShawhan/KeysightTestAutomation/raw/refs/heads/main/Runner.1.13.0-alpha.84.1+b4b4b421.1203-enable-more-runners-on-a-.Linux.arm64.TapPackage"

# Path to this script's directory for finding Instruments.xml
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"


#############################################
#            DEPENDENCY CHECKS              #
#############################################

# We intentionally do NOT use 'set -e' so we can log errors properly if something fails.
# We'll do explicit error checks instead.

function check_command_exists() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] '$cmd' is not installed or not in PATH. Please install it and retry."
    return 1
  fi
  return 0
}

function check_dependencies() {
  local missing=0
  for cmd in dotnet expect ss unzip curl; do
    check_command_exists "$cmd" || missing=1
  done
  if (( missing )); then
    echo "[ERROR] Missing one or more required commands. Exiting."
    exit 1
  fi
  
  # Check for Instruments.xml file in the script directory
  if [[ ! -f "${SCRIPT_DIR}/../taprunner/Instruments.xml" ]]; then
    echo "[ERROR] Instruments.xml file not found in ${SCRIPT_DIR}../taprunner/. Please make sure it exists."
    exit 1
  fi
}

#############################################
#         UTILITY & HELPER FUNCTIONS        #
#############################################

##
# usage()
# Prints usage info and exits.
##
function usage() {
  echo "Usage:"
  echo "  $0 start <number_of_runners> <registration_token>"
  echo "  $0 stop"
  exit 1
}

##
# find_existing_max()
#   Scans runner_1..runner_MAX_RUNNERS, returns the highest index that exists.
#   If none exist, returns 0.
##
function find_existing_max() {
  local max_found=0
  for i in $(seq 1 "$MAX_RUNNERS"); do
    local folder="$HOME/runner_$i"
    if [[ -d "$folder" ]]; then
      max_found="$i"
    fi
  done
  echo "$max_found"
}

##
# is_port_free(port)
#   Returns 0 if free, 1 if busy.
#   Uses 'ss' to check for an active listener on that port.
##
function is_port_free() {
  local port="$1"
  if ss -tulpn 2>/dev/null | grep -q ":$port "; then
    return 1  # busy
  else
    return 0  # free
  fi
}

##
# auto_unregister(port)
#   Uses 'expect' to pipe "0" to `tap runner unregister`.
#   We do a short sleep so the server can finalize removal.
##
function auto_unregister() {
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

  # Let it settle
  sleep 5
}

TEMPLATE_DIR="$HOME/runner_template"
TEMPLATE_READY_FLAG="$TEMPLATE_DIR/.ready"

### 1. Helper: build template exactly once
build_template_if_needed() {
    if [[ -f "$TEMPLATE_READY_FLAG" ]]; then
        echo "[INFO] Using cached runner template at $TEMPLATE_DIR"
        return
    fi

    echo "[INFO] Creating fresh runner template …"
    rm -rf "$TEMPLATE_DIR"
    mkdir -p "$TEMPLATE_DIR"
    pushd "$TEMPLATE_DIR" >/dev/null || exit 1

    curl -sSL -o opentap.zip "$OPENTAP_BASE_DOWNLOAD" || {
        echo "[ERROR] Failed to download OpenTAP"; exit 1; }
    unzip -q opentap.zip -d ./ && rm opentap.zip
    chmod +x ./tap

    cp "${SCRIPT_DIR}/../taprunner/CustomRunner.TapPackage" custom_runner.tap_package
    ./tap package install custom_runner.tap_package >/dev/null
    rm custom_runner.tap_package

    ./tap package install PythonExamples --version rc || true

    mkdir -p Settings/Bench/Default
    cp "${SCRIPT_DIR}/../taprunner/Instruments.xml" Settings/Bench/Default/

    popd >/dev/null
    touch "$TEMPLATE_READY_FLAG"
    echo "[INFO] Runner template prepared."
}

#############################################
#           START RUNNERS FUNCTION          #
#############################################

function start_runners() {

  build_template_if_needed

  local num_runners="$1"
  local registration_token="$2"

  # Basic checks
  if (( num_runners < 1 )); then
    echo "[ERROR] Number of runners must be >= 1."
    exit 1
  fi
  if (( num_runners > MAX_RUNNERS )); then
    echo "[ERROR] Requested $num_runners runners, but the script caps at $MAX_RUNNERS."
    exit 1
  fi

  # Check that we have enough available ports
  local available_ports=$((MAX_PORT - STARTING_PORT + 1))
  if (( num_runners > available_ports )); then
    echo "[ERROR] Requested $num_runners runners, but only $available_ports ports are in [$STARTING_PORT..$MAX_PORT]."
    exit 1
  fi

  # Determine how many runners already exist
  local existing_max
  existing_max="$(find_existing_max)"
  echo "[INFO] Highest existing runner index so far: $existing_max"

  # The next new runner index to create
  local start_index=$(( existing_max + 1 ))

  # We'll define offset = existing_max, so the next runner tries port = STARTING_PORT + offset
  local offset="$existing_max"

  echo "[INFO] Attempting to create $num_runners new runner(s), starting at runner_$start_index."

  local runners_started=0

  # Main loop to create N new runners
  for (( count = 1; count <= num_runners; count++ )); do
    local runner_index=$(( start_index + count - 1 ))
    local runner_folder="$HOME/runner_${runner_index}"
    local current_port=0

    # Find the next free port
    while true; do
      current_port=$(( STARTING_PORT + offset ))
      if (( current_port > MAX_PORT )); then
        echo "[ERROR] Ran out of ports before starting all $num_runners runners. Created $runners_started so far."
        exit 1
      fi
      if is_port_free "$current_port"; then
        # We found a free port
        break
      else
        echo "[WARNING] Port $current_port is busy. Checking the next one..."
        (( offset++ ))
      fi
    done

    # Now current_port is free; let's create the runner
    echo "----------------------------------------------------"
    echo "[INFO] Creating runner #$runner_index in $runner_folder on port $current_port"
    echo "[INFO] (This is runner $count of $num_runners requested this run)"

    # 1) Create fresh folder
    rm -rf "$runner_folder" || true
    mkdir -p "$runner_folder"

   # 2‑3) Clone the template instead of downloading / installing
    echo "[INFO] Cloning template into $runner_folder …"
    cp -a "$TEMPLATE_DIR" "$runner_folder"

    # 4) Register the Runner
    echo "[INFO] Registering the Runner..."
    ./tap runner register --url "$TAP_URL" --registrationToken "$registration_token" >/dev/null 2>&1 || {
      echo "[ERROR] tap runner register failed."
      exit 1
    }

    echo "[INFO] Starting the Runner on port $current_port..."
    nohup env OPENTAP_RUNNER_SERVER_PORT="$current_port" ./tap runner start > runner.log 2>&1 &

    echo "[INFO] Runner #$runner_index is started. Logs in $runner_folder/runner.log."
    (( runners_started++ ))
    (( offset++ ))

    # Return to home directory
    cd ~ || true
  done

  echo "----------------------------------------------------"
  echo "[INFO] Created $runners_started new runner(s) in this session."
}

#############################################
#             STOP RUNNERS FUNCTION         #
#############################################

function stop_runners() {
  echo "[INFO] Stopping and unregistering all runners (1..$MAX_RUNNERS)."

  # We attempt up to MAX_RUNNERS possible indexes
  for i in $(seq 1 "$MAX_RUNNERS"); do
    local runner_folder="$HOME/runner_$i"
    local runner_port=$(( STARTING_PORT + i - 1 ))

    if [[ -d "$runner_folder" ]]; then
      echo "----------------------------------------------------"
      echo "[INFO] Found runner folder: $runner_folder; stopping it..."
      cd "$runner_folder" || {
        echo "[ERROR] Could not cd to $runner_folder"
        continue
      }

      # Attempt graceful unregistration
      if [[ -x ./tap ]]; then
        echo "[INFO] Unregistering runner #$i on port $runner_port..."
        auto_unregister "$runner_port" || {
          echo "[WARN] auto_unregister failed or was incomplete."
        }
        echo "[INFO] Stopping local Tap runner on port $runner_port…"
        pgrep -f "OPENTAP_RUNNER_SERVER_PORT=${runner_port}" | \
          xargs -r kill || echo "[WARN] no local runner to kill"
      else
        echo "[WARN] ./tap not found or not executable in $runner_folder."
      fi

      cd ~
      rm -rf "$runner_folder"
      echo "[INFO] Removed $runner_folder."
    fi
  done

  echo "----------------------------------------------------"
  echo "[INFO] All possible runners have been unregistered and removed."
}


#############################################
#                 MAIN LOGIC                #
#############################################

# 1) Check required commands
check_dependencies

# 2) Parse arguments
if [[ $# -lt 1 ]]; then
  usage
fi

COMMAND="$1"

case "$COMMAND" in
  start)
    if [[ $# -ne 3 ]]; then
      usage
    fi
    num="$2"
    reg_token="$3"
    start_runners "$num" "$reg_token"
    ;;
  stop)
    stop_runners
    ;;
  *)
    usage
    ;;
esac