#!/usr/bin/env bash
source ./metrics_tools.sh

set -e

# --- CONFIGURATION ---
STARTING_PORT=20110
MAX_RUNNERS=97
TAP_URL="https://test-automation.pw.keysight.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
METRICS_DIR="${SCRIPT_DIR}/metrics"

# Create metrics directory if it doesn't exist
mkdir -p "$METRICS_DIR"

# Function to check if runners directories exist
function check_runners_exist() {
  local count=0
  for i in $(seq 1 "$MAX_RUNNERS"); do
    if [[ -d "$HOME/runner_$i" ]]; then
      count=$((count + 1))
    fi
  done
  
  if [[ $count -lt $1 ]]; then
    echo "[ERROR] Not enough runners found. Found $count, but need $1."
    echo "[INFO] Please run the multi_runner.sh script to create more runners."
    exit 1
  fi
  
  echo "[INFO] Found $count runners, which is sufficient for testing."
}

# Function to verify the test plan exists in the script directory
function verify_test_plan() {
  local test_plan="$1"
  local test_plan_path="${SCRIPT_DIR}/${test_plan}"
  
  if [[ ! -f "$test_plan_path" ]]; then
    echo "[ERROR] Test plan not found: $test_plan_path"
    echo "[INFO] Please place the test plan in the same directory as this script."
    exit 1
  fi
  
  echo "[INFO] Found test plan: $test_plan_path"
}

# Function to run a test plan on a specific runner
function run_test_plan() {
  local runner_id=$1
  local test_plan=$2
  local is_baseline=$3
  local output_file="${METRICS_DIR}/runner_${runner_id}_metrics.log"
  local runner_dir="$HOME/runner_$runner_id"
  local runner_port=$((STARTING_PORT + runner_id - 1))
  local test_plan_path="${SCRIPT_DIR}/${test_plan}"
  # port might not be accurate because noisyNeighbors.sh assumes every port is open when creating runners
  echo "[INFO] Runner #$runner_id executing test plan: $test_plan (Port: $runner_port)"
  
  if [[ ! -d "$runner_dir" ]]; then
    echo "[ERROR] Runner directory $runner_dir not found."
    return 1
  fi
  
  # Capture start timestamp with millisecond precision
  local start_time=$(date +%s.%N)
  
  # Move to runner directory but use the test plan from the script directory
  cd "$runner_dir" || return 1
  
  # Execute the test plan and capture output
  if [[ "$is_baseline" == "true" ]]; then
    # For baseline, capture detailed output
    ./tap run "$test_plan_path" 2>&1 | tee "${METRICS_DIR}/runner_${runner_id}_output.log" || {
      echo "[ERROR] Failed to run test plan on runner #$runner_id."
      return 1
    }
  else
    # For concurrent runners, just capture basic output
    ./tap run "$test_plan_path" > "${METRICS_DIR}/runner_${runner_id}_output.log" 2>&1 || {
      echo "[ERROR] Failed to run test plan on runner #$runner_id."
      return 1
    }
  fi
  
  # Capture end timestamp
  local end_time=$(date +%s.%N)
  
  # Calculate runtime in seconds with millisecond precision
  local runtime=$(echo "$end_time - $start_time" | bc)
  
  # Log the execution time
  echo "runner_id=$runner_id,test_plan=$test_plan,start=$start_time,end=$end_time,runtime=$runtime" > "$output_file"
  echo "[INFO] Runner #$runner_id completed in $runtime seconds"
}

# Enhanced function to collect system resource usage during test execution
function monitor_resources() {
  local output_file="${METRICS_DIR}/resource_usage.log"
  
  echo "timestamp,cpu_percent,memory_kb,disk_io_read_kb,disk_io_write_kb,network_rx_bytes,network_tx_bytes,load_avg" > "$output_file"
  
  while [[ -f "${METRICS_DIR}/.monitoring_active" ]]; do
    local timestamp
    timestamp=$(date +%s)
    
    # Instead of summing, take the maximum of each field (instantaneous snapshot)
    local cpu_usage
    cpu_usage=$(ps -e -o pcpu= | awk 'BEGIN {max=0} {if($1>max) max=$1} END {print max}')
    
    unique_mem_usage=$(awk '/MemTotal:/ {total=$2} /MemAvailable:/ {avail=$2} END {print total - avail}' /proc/meminfo)
    
    # For Disk I/O, if you want to take a snapshot instead of a sum, you might want to use a similar approach.
    # But often for I/O it makes sense to sum or use a tool that already provides instantaneous rates.
    if command -v iostat &>/dev/null; then
      # This command already outputs the snapshot for the given interval.
      local disk_io
      disk_io=$(iostat -d -k 1 2 | tail -n 2 | head -n 1)
      local disk_read
      disk_read=$(echo "$disk_io" | awk '{print $3}')
      local disk_write
      disk_write=$(echo "$disk_io" | awk '{print $4}')
    else
      local disk_read=0
      local disk_write=0
    fi

    # For network traffic, you might want to keep the sum since these counters are cumulative.
    if [[ -f /proc/net/dev ]]; then
      local net_stats
      net_stats=$(cat /proc/net/dev | grep -v 'lo:' | grep ':' | awk '{rx+=$2; tx+=$10} END {print rx","tx}')
      local net_rx
      net_rx=$(echo "$net_stats" | cut -d',' -f1)
      local net_tx
      net_tx=$(echo "$net_stats" | cut -d',' -f2)
    else
      local net_rx=0
      local net_tx=0
    fi
    
    local load_avg
    load_avg=$(cut -d ' ' -f1 /proc/loadavg)
    
    # Write out the snapshot for this interval
    echo "$timestamp,$cpu_usage,$unique_mem_usage,$disk_read,$disk_write,$net_rx,$net_tx,$load_avg" >> "$output_file"
    sleep 1
  done
}

# Function to monitor detailed CPU metrics
function monitor_detailed_cpu() {
  local output_file="${METRICS_DIR}/cpu_detailed.log"
  
  echo "timestamp,user,nice,system,idle,iowait,irq,softirq,steal,guest" > "$output_file"
  
  while [[ -f "${METRICS_DIR}/.monitoring_active" ]]; do
    local timestamp=$(date +%s)
    if [[ -f /proc/stat ]]; then
      local cpu_stats=$(grep '^cpu ' /proc/stat | awk '{print $2","$3","$4","$5","$6","$7","$8","$9","$10}')
      echo "$timestamp,$cpu_stats" >> "$output_file"
    fi
    sleep 1
  done
}

# Function to monitor CPU usage per core
function monitor_cpu_cores() {
  local output_file="${METRICS_DIR}/cpu_cores.log"
  local num_cores=$(grep -c ^processor /proc/cpuinfo)
  
  # Create header with core numbers
  local header="timestamp"
  for i in $(seq 0 $((num_cores-1))); do
    header="$header,core$i"
  done
  
  echo "$header" > "$output_file"
  
  while [[ -f "${METRICS_DIR}/.monitoring_active" ]]; do
    local timestamp=$(date +%s)
    local line="$timestamp"
    
    # Get per-core CPU usage with mpstat if available
    if command -v mpstat &>/dev/null; then
      local cores_data=$(mpstat -P ALL 1 1 | grep -E "^[0-9]+" | awk '{print 100-$NF}')
      
      # Skip the first line which is the average
      local core_values=$(echo "$cores_data" | tail -n +2)
      
      # Append each core's usage to the line
      while read -r usage; do
        line="$line,$usage"
      done <<< "$core_values"
    else
      # Fall back to /proc/stat if mpstat is not available
      for i in $(seq 0 $((num_cores-1))); do
        if [[ -f /proc/stat ]]; then
          local core_info=$(grep "^cpu$i " /proc/stat)
          local user=$(echo "$core_info" | awk '{print $2}')
          local nice=$(echo "$core_info" | awk '{print $3}')
          local system=$(echo "$core_info" | awk '{print $4}')
          local idle=$(echo "$core_info" | awk '{print $5}')
          local total=$((user + nice + system + idle))
          local usage=$(echo "scale=2; 100 - ($idle * 100 / $total)" | bc)
          line="$line,$usage"
        else
          line="$line,0"
        fi
      done
    fi
    
    echo "$line" >> "$output_file"
    sleep 1
  done
}

# Function to monitor detailed memory statistics
function monitor_detailed_memory() {
  local output_file="${METRICS_DIR}/memory_detailed.log"
  
  echo "timestamp,total_kb,free_kb,used_kb,buffers_kb,cached_kb,available_kb,swap_total_kb,swap_free_kb" > "$output_file"
  
  while [[ -f "${METRICS_DIR}/.monitoring_active" ]]; do
    local timestamp=$(date +%s)
    
    if [[ -f /proc/meminfo ]]; then
      # Extract memory statistics
      local mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
      local mem_free=$(grep MemFree /proc/meminfo | awk '{print $2}')
      local mem_buffers=$(grep Buffers /proc/meminfo | awk '{print $2}')
      local mem_cached=$(grep "^Cached:" /proc/meminfo | awk '{print $2}')
      local mem_available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
      local swap_total=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
      local swap_free=$(grep SwapFree /proc/meminfo | awk '{print $2}')
      local mem_used=$((mem_total - mem_free - mem_buffers - mem_cached))
      
      echo "$timestamp,$mem_total,$mem_free,$mem_used,$mem_buffers,$mem_cached,$mem_available,$swap_total,$swap_free" >> "$output_file"
    fi
    sleep 1
  done
}

# Function to monitor network connections
function monitor_network_connections() {
  local output_file="${METRICS_DIR}/network_connections.log"
  
  echo "timestamp,total_connections,established,time_wait,close_wait" > "$output_file"
  
  while [[ -f "${METRICS_DIR}/.monitoring_active" ]]; do
    local timestamp=$(date +%s)
    
    if command -v netstat &>/dev/null; then
      # Get connection counts by state
      local netstat_output=$(netstat -an)
      local total=$(echo "$netstat_output" | wc -l)
      local established=$(echo "$netstat_output" | grep ESTABLISHED | wc -l)
      local time_wait=$(echo "$netstat_output" | grep TIME_WAIT | wc -l)
      local close_wait=$(echo "$netstat_output" | grep CLOSE_WAIT | wc -l)
      
      echo "$timestamp,$total,$established,$time_wait,$close_wait" >> "$output_file"
    elif command -v ss &>/dev/null; then
      # Alternative using ss command
      local ss_output=$(ss -tan)
      local total=$(echo "$ss_output" | wc -l)
      local established=$(echo "$ss_output" | grep ESTAB | wc -l)
      local time_wait=$(echo "$ss_output" | grep TIME-WAIT | wc -l)
      local close_wait=$(echo "$ss_output" | grep CLOSE-WAIT | wc -l)
      
      echo "$timestamp,$total,$established,$time_wait,$close_wait" >> "$output_file"
    fi
    
    sleep 1
  done
}


# Main script logic
clear
echo "======================================================"
echo "          NOISY NEIGHBORS PERFORMANCE TEST            "
echo "======================================================"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <number_of_runners>"
  exit 1
fi

N=$1

if (( N < 2 )); then
  echo "[ERROR] At least 2 runners are required (1 baseline + 1 concurrent)."
  exit 1
fi

if (( N > MAX_RUNNERS )); then
  echo "[ERROR] Invalid number of runners. Must be between 2 and $MAX_RUNNERS."
  exit 1
fi

# Check if we have enough runner directories
check_runners_exist "$N"

# Clean up previous metrics
rm -rf "${METRICS_DIR}"/*.log
mkdir -p "${METRICS_DIR}/charts"

# Get test plan name from user
read -p "Enter the test plan name to execute (must be in this directory): " TEST_PLAN

# Verify the test plan exists in the script directory
verify_test_plan "$TEST_PLAN"

echo "[INFO] Starting performance test with $N runners"
echo "[INFO] Baseline: Runner #1 running solo"
echo "[INFO] Then: Runner #1 plus $(( N - 1 )) concurrent runners"

# Create a file flag to indicate monitoring should continue
touch "${METRICS_DIR}/.monitoring_active"

# Start all monitoring processes in the background
declare -a MONITOR_PIDS

# Start resource monitoring in the background
monitor_resources &
MONITOR_PIDS+=($!)

# Start detailed CPU monitoring
monitor_detailed_cpu &
MONITOR_PIDS+=($!)

# Start per-core CPU monitoring
monitor_cpu_cores &
MONITOR_PIDS+=($!)

# Start detailed memory monitoring
monitor_detailed_memory &
MONITOR_PIDS+=($!)

# Start network connection monitoring
monitor_network_connections &
MONITOR_PIDS+=($!)

# First: Run baseline test with just Runner #1
echo "----------------------------------------------------"
echo "[INFO] PHASE 1: Running baseline test on Runner #1 only..."
run_test_plan 1 "$TEST_PLAN" true
local_baseline_runtime=$(grep -oP 'runtime=\K[0-9.]+' "${METRICS_DIR}/runner_1_metrics.log")
echo "[INFO] Baseline completed in $local_baseline_runtime seconds"

# Now run the same test with noisy neighbors
echo "----------------------------------------------------"
echo "[INFO] PHASE 2: Running tests with $((N-1)) concurrent runners..."

# Array to hold PIDs of all runners
declare -a RUNNER_PIDS

# Start all runners concurrently
for (( i=2; i<=N; i++ )); do
  # Run each test plan in a subshell and capture its PID
  (run_test_plan "$i" "$TEST_PLAN" false) &
  RUNNER_PIDS+=($!)
  # Small delay to stagger starts slightly
  sleep 0.5
done

echo "[INFO] Started $(( N - 1 )) concurrent runners."
echo "[INFO] Waiting for all test runners to complete..."

# Wait for all runners to complete with timeout
TIMEOUT=600  # 10 min max
START_TIME=$(date +%s)

# Function to check if all runners are complete
function all_runners_complete() {
  for pid in "${RUNNER_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      # Process is still running
      return 1
    fi
  done
  # All processes have completed
  return 0
}

# Wait for all processes to finish with a timeout
COMPLETED=false
while ! $COMPLETED; do
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
  
  # Check for timeout
  if (( ELAPSED_TIME > TIMEOUT )); then
    echo "[WARNING] Timeout reached. Terminating any remaining test runners..."
    for pid in "${RUNNER_PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
    break
  fi
  
  # Check if all processes have completed
  if all_runners_complete; then
    COMPLETED=true
    echo "[INFO] All test runners have completed successfully."
  else
    echo "[INFO] Waiting for runners to complete... (${ELAPSED_TIME}s elapsed)"
    sleep 5
  fi
done

# Stop resource monitoring by removing the flag file
rm -f "${METRICS_DIR}/.monitoring_active"
# Give the monitoring process a moment to detect the flag is gone
sleep 2
# Kill the monitoring processes if they're still running
for pid in "${MONITOR_PIDS[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
  fi
done

echo "[INFO] Analyzing performance metrics..."

# Analyze performance impact
analyze_metrics

echo "======================================================"
echo "          TEST COMPLETED SUCCESSFULLY                 "
echo "======================================================"