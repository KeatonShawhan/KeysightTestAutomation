#!/usr/bin/env bash
#
# multi_runner.sh
#
# A script to spin up multiple OpenTAP runners on a Raspberry Pi, each bound
# to a unique port. It supports a graceful teardown, automatically unregistering
# and removing all runner folders. If a port is already in use, it automatically
# retries with the next port, unregistering and deleting the failed runner attempt.
#
# Usage:
#   ./multi_runner.sh start <number_of_runners> <registration_token>
#   ./multi_runner.sh stop
#
# Disclaimer: This requires .NET and 'expect' installed on the Pi.

set -e

# --- CONFIGURATION ---
STARTING_PORT=20113
MAX_PORT=20220
MAX_RUNNERS=97
TAP_URL="https://test-automation.pw.keysight.com"  # URL for 'tap runner register'
OPENTAP_BASE_DOWNLOAD="https://packages.opentap.io/4.0/Objects/Packages/OpenTAP?os=Linux&architecture=arm64"

# The custom runner TapPackage you provided:
RUNNER_PACKAGE_URL="https://github.com/KeatonShawhan/KeysightTestAutomation/raw/refs/heads/main/Runner.1.13.0-alpha.84.1+b4b4b421.1203-enable-more-runners-on-a-.Linux.arm64.TapPackage"

# Time to wait (in seconds) after starting a runner to see if it fails with a "port in use" error.
WAIT_FOR_ERROR=5

# --- HELPER FUNCTIONS ---

function usage() {
  echo "Usage:"
  echo "  $0 start <number_of_runners> <registration_token>"
  echo "  $0 stop"
  exit 1
}

function check_dotnet() {
  if ! command -v dotnet &>/dev/null; then
    echo "[ERROR] .NET runtime not found. Please install .NET before running this script."
    exit 1
  fi
}

function check_expect() {
  if ! command -v expect &>/dev/null; then
    echo "[ERROR] 'expect' utility is not installed. Please install it (e.g., sudo apt-get install expect)."
    exit 1
  fi
}

##
# Use expect to send "0" to the interactive prompt from 'tap runner unregister'.
# We also add a small delay after sending the input.
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
  # Brief delay to let unregistration finish
  sleep 5
}

##
# Launch a runner in the background and check its log for "address already in use."
# Return codes:
#   0 = success
#   1 = "address already in use"
#   2 = some other fatal error (not currently implemented, but you can add checks if needed)
##
function attempt_start_runner() {
  local port="$1"

  # Start the runner in background
  nohup env OPENTAP_RUNNER_SERVER_PORT="$port" ./tap runner start > runner.log 2>&1 &

  # Wait a few seconds to see if an error surfaces in runner.log
  sleep "$WAIT_FOR_ERROR"

  if grep -q "bind: address already in use" runner.log; then
    echo "[ERROR] Port $port is already in use. Will attempt to unregister and retry with another port."
    return 1
  fi

  # If we didn't detect the specific port error, assume success
  return 0
}

function start_runners() {
  local num_runners="$1"
  local registration_token="$2"

  # Ensure the user hasn't requested more runners than allowed
  if (( num_runners > MAX_RUNNERS )); then
    echo "[ERROR] Requested $num_runners runners, but the script caps at $MAX_RUNNERS."
    exit 1
  fi

  # Also ensure we have enough ports in the range
  local available_ports=$(( MAX_PORT - STARTING_PORT + 1 ))
  if (( num_runners > available_ports )); then
    echo "[ERROR] Requested $num_runners runners, but only $available_ports ports are available ($STARTING_PORT..$MAX_PORT)."
    exit 1
  fi

  echo "[INFO] Attempting to start $num_runners runner(s). Registration Token: $registration_token"

  local current_port="$STARTING_PORT"

  for (( i=1; i<=num_runners; i++ )); do
    local runner_folder="$HOME/runner_$i"

    # We may need to keep retrying on new ports if the current one is in use
    local started=0
    while [[ $started -eq 0 ]]; do
      if (( current_port > MAX_PORT )); then
        echo "[ERROR] No more ports available. Could only start $((i-1)) runners."
        exit 1
      fi

      echo "----------------------------------------------------"
      echo "[INFO] Setting up Runner #$i in folder: $runner_folder on port: $current_port"

      # 1. Create fresh folder
      rm -rf "$runner_folder" 2>/dev/null || true
      mkdir -p "$runner_folder"
      cd "$runner_folder"

      # 2. Download & install base OpenTAP
      echo "[INFO] Downloading base OpenTAP from $OPENTAP_BASE_DOWNLOAD ..."
      curl -sSL -o opentap.zip "$OPENTAP_BASE_DOWNLOAD"
      unzip -q opentap.zip -d ./
      rm opentap.zip
      chmod +x ./tap

      # 3. Install the custom Runner package
      echo "[INFO] Downloading custom Runner from $RUNNER_PACKAGE_URL ..."
      curl -sSL -o custom_runner.tap_package "$RUNNER_PACKAGE_URL"
      echo "[INFO] Installing the custom Runner TapPackage..."
      ./tap package install custom_runner.tap_package >/dev/null 2>&1
      rm custom_runner.tap_package

      # 4. Register the Runner
      echo "[INFO] Registering the Runner with token..."
      ./tap runner register --url "$TAP_URL" --registrationToken "$registration_token" >/dev/null 2>&1

      # 5. Attempt to start the Runner on current_port
      echo "[INFO] Trying port $current_port..."
      if attempt_start_runner "$current_port"; then
        # success
        echo "[INFO] Runner #$i started successfully on port $current_port."
        started=1
      else
        # attempt_start_runner returned non-zero => port in use
        echo "[INFO] Unregistering the runner attempt on port $current_port..."
        auto_unregister "$current_port" || true
        cd ..
        rm -rf "$runner_folder"
        echo "[INFO] Freed up runner folder; will try the next port."
        ((current_port++))
        continue
      fi

      # If we get here, the runner started successfully, move on
      cd ~
    done

    # Move to next port for the next runner
    ((current_port++))
  done

  echo "----------------------------------------------------"
  echo "[INFO] Successfully started $num_runners runner(s). Logs are in each runner folder's runner.log."
}

function stop_runners() {
  echo "[INFO] Stopping and unregistering all runners (non-interactive)."

  for i in $(seq 1 "$MAX_RUNNERS"); do
    local runner_folder="$HOME/runner_$i"
    local runner_port=$((STARTING_PORT + i - 1))

    if [[ -d "$runner_folder" ]]; then
      echo "----------------------------------------------------"
      echo "[INFO] Stopping runner in folder: $runner_folder"
      cd "$runner_folder"

      # Gracefully unregister the runner
      if [[ -x "./tap" ]]; then
        echo "[INFO] Unregistering Runner #$i on port $runner_port..."
        auto_unregister "$runner_port" || true
      fi

      cd ~
      rm -rf "$runner_folder"
      echo "[INFO] Runner #$i unregistered and folder removed."
    fi
  done

  echo "----------------------------------------------------"
  echo "[INFO] All runners have been unregistered and removed."
}

# --- MAIN LOGIC ---

# Check dependencies
check_dotnet
check_expect

# Parse arguments
if [[ $# -lt 1 ]]; then
  usage
fi

COMMAND="$1"

case "$COMMAND" in
  start)
    if [[ $# -ne 3 ]]; then
      usage
    fi
    START_NUM="$2"
    REG_TOKEN="$3"
    start_runners "$START_NUM" "$REG_TOKEN"
    ;;
  stop)
    stop_runners
    ;;
  *)
    usage
    ;;
esac

