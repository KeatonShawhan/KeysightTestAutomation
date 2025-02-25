#!/usr/bin/env bash
#
# multi_runner.sh
# A script to spin up multiple OpenTAP runners on a Raspberry Pi, each bound to a unique port.
# It also supports a graceful teardown, unregistering and removing all runner folders.
#
# Usage:
#   ./multi_runner.sh start N <registrationToken>
#   ./multi_runner.sh stop
#
# Disclaimer: This requires a working .NET installation on the Raspberry Pi.
#

set -e

# --- CONFIGURATION ---
STARTING_PORT=20112
MAX_PORT=20120
TAP_URL="https://test-automation.pw.keysight.com"  # URL used in the 'tap runner register' command
OPENTAP_BASE_DOWNLOAD="https://packages.opentap.io/4.0/Objects/Packages/OpenTAP?os=Linux&architecture=arm64"
OPENTAP_RUNNER_VERSION="Runner:1.12.2"

# --- HELPER FUNCTIONS ---

function usage() {
  echo "Usage:"
  echo "  $0 start <number_of_runners> <registration_token>"
  echo "  $0 stop"
  exit 1
}

function check_dotnet() {
  if ! command -v dotnet &> /dev/null; then
    echo "[ERROR] .NET runtime not found. Please install .NET before running this script."
    exit 1
  fi
}

function start_runners() {
  local num_runners="$1"
  local registration_token="$2"

  # Validate runner count based on available port range
  local max_runners=$((MAX_PORT - STARTING_PORT + 1))
  if (( num_runners > max_runners )); then
    echo "[ERROR] You requested $num_runners runners, but only $max_runners ports are available ($STARTING_PORT to $MAX_PORT)."
    exit 1
  fi

  echo "[INFO] Starting $num_runners runner(s). Registration Token: $registration_token"

  for (( i=1; i<=num_runners; i++ )); do
    local runner_folder="$HOME/runner_$i"
    local runner_port=$((STARTING_PORT + i - 1))

    echo "----------------------------------------------------"
    echo "[INFO] Setting up Runner #$i in folder: $runner_folder on port: $runner_port"

    # 1. Create a new folder for the runner
    rm -rf "$runner_folder" 2>/dev/null || true
    mkdir -p "$runner_folder"
    cd "$runner_folder"

    # 2. Download & install OpenTAP
    echo "[INFO] Downloading OpenTAP..."
    curl -sSL -o opentap.zip "$OPENTAP_BASE_DOWNLOAD"
    unzip -q ./opentap.zip -d ./
    rm ./opentap.zip
    chmod +x ./tap  # Make tap executable

    # 3. Install the Runner plugin
    echo "[INFO] Installing the Runner plugin: $OPENTAP_RUNNER_VERSION"
    ./tap image install "$OPENTAP_RUNNER_VERSION" >/dev/null 2>&1

    # 4. Register the Runner
    echo "[INFO] Registering the Runner with token..."
    ./tap runner register --url "$TAP_URL" --registrationToken "$registration_token" >/dev/null 2>&1

    # 5. Start the Runner in the background on the specified port
    echo "[INFO] Starting the Runner in the background..."
    nohup env OPENTAP_RUNNER_SERVER_PORT="$runner_port" ./tap runner start > runner.log 2>&1 &

    echo "[INFO] Runner #$i setup complete."
  done

  echo "----------------------------------------------------"
  echo "[INFO] All $num_runners runner(s) are started. Logs are in each runner folder's runner.log."
}

function stop_runners() {
  echo "[INFO] Stopping and unregistering all runners."

  # Loop over all possible runners from 1 to 9 (given our max is 9)
  for i in $(seq 1 9); do
    local runner_folder="$HOME/runner_$i"
    local runner_port=$((STARTING_PORT + i - 1))

    if [[ -d "$runner_folder" ]]; then
      echo "----------------------------------------------------"
      echo "[INFO] Stopping runner in folder: $runner_folder"

      cd "$runner_folder"

      # 1. Gracefully unregister the runner
      if [[ -x "./tap" ]]; then
        echo "[INFO] Unregistering Runner #$i..."
        # We set the port environment in case it needs it to find the correct runner instance
        env OPENTAP_RUNNER_SERVER_PORT="$runner_port" ./tap runner unregister || true
      fi

      cd ..
      rm -rf "$runner_folder"  # Remove the folder and all logs/files
      echo "[INFO] Runner #$i unregistered and folder removed."
    fi
  done

  echo "----------------------------------------------------"
  echo "[INFO] All runners have been unregistered and removed."
}

# --- MAIN LOGIC ---

# Check for .NET first
check_dotnet

# Parse command
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

