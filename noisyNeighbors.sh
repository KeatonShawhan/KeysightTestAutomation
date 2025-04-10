#!/usr/bin/env bash

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
    local timestamp=$(date +%s)
    local cpu_usage=$(ps -e -o pcpu= | awk '{sum+=$1} END {print sum}')
    local mem_usage=$(ps -e -o rss= | awk '{sum+=$1} END {print sum}')
    
    # Disk I/O (read/write in KB/s)
    if command -v iostat &>/dev/null; then
      local disk_io=$(iostat -d -k 1 2 | tail -n 2 | head -n 1)
      local disk_read=$(echo "$disk_io" | awk '{print $3}')
      local disk_write=$(echo "$disk_io" | awk '{print $4}')
    else
      local disk_read=0
      local disk_write=0
    fi
    
    # Network traffic (bytes received/transmitted)
    if [[ -f /proc/net/dev ]]; then
      local net_stats=$(cat /proc/net/dev | grep -v 'lo:' | grep ':' | awk '{rx+=$2; tx+=$10} END {print rx","tx}')
      local net_rx=$(echo "$net_stats" | cut -d',' -f1)
      local net_tx=$(echo "$net_stats" | cut -d',' -f2)
    else
      local net_rx=0
      local net_tx=0
    fi
    
    # Load average (1min)
    local load_avg=$(cut -d ' ' -f1 /proc/loadavg)
    
    echo "$timestamp,$cpu_usage,$mem_usage,$disk_read,$disk_write,$net_rx,$net_tx,$load_avg" >> "$output_file"
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

# Function to generate visualization charts from collected metrics
function generate_charts() {
  if ! command -v gnuplot &>/dev/null; then
    echo "[WARNING] gnuplot not found. Skipping chart generation."
    return
  fi
  
  local charts_dir="${METRICS_DIR}/charts"
  mkdir -p "$charts_dir"
  
  echo "[INFO] Generating performance charts..."
  
  # Get the first timestamp from the resource_usage.log to use as start time
  if [[ -f "${METRICS_DIR}/resource_usage.log" ]] && [[ $(wc -l < "${METRICS_DIR}/resource_usage.log") -gt 1 ]]; then
    local start_ts=$(head -2 "${METRICS_DIR}/resource_usage.log" | tail -1 | cut -d',' -f1)
    
    # CPU usage chart
    gnuplot <<EOF
set terminal png size 800,600
set output '$charts_dir/cpu_usage.png'
set title 'CPU Usage Over Time'
set xlabel 'Time (seconds from start)'
set ylabel 'CPU Usage (%)'
set datafile separator ','
set grid
start_time = $start_ts
plot '$METRICS_DIR/resource_usage.log' using (\$1-start_time):2 with lines title 'CPU Usage' lw 2
EOF


    # Memory usage chart
    gnuplot <<EOF
set terminal png size 800,600
set output '$charts_dir/memory_usage.png'
set title 'Memory Usage Over Time'
set xlabel 'Time (seconds from start)'
set ylabel 'Memory Usage (MB)'
set datafile separator ','
set grid
start_time = $start_ts
plot '$METRICS_DIR/resource_usage.log' using (\$1-start_time):(\$3/1024) with lines title 'Memory Usage' lw 2
EOF

    # Load average chart
    gnuplot <<EOF
set terminal png size 800,600
set output '$charts_dir/load_average.png'
set title 'System Load Average'
set xlabel 'Time (seconds from start)'
set ylabel 'Load Average (1 min)'
set datafile separator ','
set grid
start_time = $start_ts
plot '$METRICS_DIR/resource_usage.log' using (\$1-start_time):8 with lines title 'Load Average' lw 2
EOF

    # Network traffic chart
    gnuplot <<EOF
set terminal png size 800,600
set output '$charts_dir/network_traffic.png'
set title 'Network Traffic'
set xlabel 'Time (seconds from start)'
set ylabel 'Traffic (KB)'
set datafile separator ','
set grid
start_time = $start_ts
plot '$METRICS_DIR/resource_usage.log' using (\$1-start_time):(\$5/1024) with lines title 'RX' lw 2, \
     '$METRICS_DIR/resource_usage.log' using (\$1-start_time):(\$6/1024) with lines title 'TX' lw 2
EOF
  else
    echo "[WARNING] Resource usage log file is missing or empty. Skipping related charts."
  fi

  # CPU cores heatmap if the file exists and has data
  if [[ -f "${METRICS_DIR}/cpu_cores.log" ]] && [[ $(wc -l < "${METRICS_DIR}/cpu_cores.log") -gt 1 ]]; then
    local start_ts=$(head -2 "${METRICS_DIR}/cpu_cores.log" | tail -1 | cut -d',' -f1)
    
    gnuplot <<EOF
set terminal png size 1000,600
set output '$charts_dir/cpu_cores_heatmap.png'
set title 'CPU Cores Usage Heatmap'
set xlabel 'Time (seconds from start)'
set ylabel 'CPU Core'
set datafile separator ','
plot 'cpu_cores.log' every ::1 using (\$1 - start_time):2 with lines title 'Core 0', \
     '' every ::1 using (\$1 - start_time):3 with lines title 'Core 1', \
     '' every ::1 using (\$1 - start_time):4 with lines title 'Core 2', \
     '' every ::1 using (\$1 - start_time):5 with lines title 'Core 3', \
     '' every ::1 using (\$1 - start_time):6 with lines title 'Core 4'
set view map
set cblabel 'Usage %'
set palette defined (0 'blue', 50 'green', 75 'yellow', 100 'red')
start_time = $start_ts
NUM_CORES=$(awk -F, '{print NF-1; exit}' "${METRICS_DIR}/cpu_cores.log")
splot '$METRICS_DIR/cpu_cores.log' using (\$1-start_time):0:2 with pm3d title ''
EOF
  fi

  echo "[INFO] Charts generated in $charts_dir"
}

# Function to analyze and display performance metrics
function analyze_metrics() {
  local baseline_file="${METRICS_DIR}/runner_1_metrics.log"
  local total_runtime=0
  local max_runtime=0
  local max_runner=1
  local min_runtime=9999999  # High enough to ensure proper min selection
  local min_runner=1
  local fastest_runtime=9999999  # Initialize for comparison
  local fastest_runner=1
  
  echo "----------------------------------------------------"
  echo "[INFO] Performance Analysis:"
  
  # Extract baseline metrics
  if [[ -f "$baseline_file" ]]; then
    local baseline_data=$(grep -oP 'runtime=\K[0-9.]+' "$baseline_file")
    if [[ -z "$baseline_data" ]]; then
      echo "[ERROR] Baseline runner log exists, but no runtime data found."
      return 1
    fi
    local baseline_runtime=$baseline_data
    echo "Baseline Runner (Runner #1): $baseline_runtime seconds"
  else
    echo "[ERROR] Could not find baseline metrics file."
    return 1
  fi

  # Analyze metrics for all runners
  echo "----------------------------------------------------"
  echo "Individual Runner Performance:"
  for i in $(seq 2 "$N"); do
    local metrics_file="${METRICS_DIR}/runner_${i}_metrics.log"
    if [[ -f "$metrics_file" ]]; then
      local runtime=$(grep -oP 'runtime=\K[0-9.]+' "$metrics_file")

      # Validate runtime extraction
      if [[ -z "$runtime" ]]; then
        echo "[WARNING] Could not extract runtime for Runner #$i. Skipping..."
        continue
      fi
      
      # Track min/max
      if (( $(echo "$runtime > $max_runtime" | bc -l) )); then
        max_runtime=$runtime
        max_runner=$i
      fi
      
      if (( $(echo "$runtime < $min_runtime" | bc -l) )); then
        min_runtime=$runtime
        min_runner=$i
      fi
      
      total_runtime=$(echo "$total_runtime + $runtime" | bc)
      
      # Compare to fastest runtime (for percentage accuracy)
      if (( $(echo "$runtime < $fastest_runtime" | bc -l) )); then
        fastest_runtime=$runtime
        fastest_runner=$i
      fi
      
      # Calculate slowdown compared to baseline with increased precision
      local slowdown=$(echo "scale=4; (($runtime / $baseline_runtime) - 1) * 100" | bc)
      
      # Format with more precision to capture small differences
      slowdown=$(printf "%.4f" "$slowdown")  # Using 4 decimal places instead of 2

      echo "Runner #$i: ${runtime} seconds (${slowdown}% slower than baseline)"
    else
      echo "[WARNING] Missing metrics file for Runner #$i. Skipping..."
    fi
  done

  # Calculate average (excluding baseline)
  if (( N > 1 )); then
    local avg_runtime=$(echo "scale=4; $total_runtime / (${N} - 1)" | bc)
    local avg_slowdown=$(echo "scale=4; ($avg_runtime / $baseline_runtime - 1) * 100" | bc)
    
    # Format with consistent precision
    avg_runtime=$(printf "%.4f" "$avg_runtime")
    avg_slowdown=$(printf "%.4f" "$avg_slowdown")
    
    echo "----------------------------------------------------"
    echo "Summary Statistics:"
    echo "Fastest Runner: #$min_runner ($min_runtime seconds)"
    echo "Slowest Runner: #$max_runner ($max_runtime seconds)"
    echo "Average Runtime: $avg_runtime seconds"
    echo "Average Slowdown: ${avg_slowdown}%"
    
    # Generate a summary file for easy reference with improved precision
    {
      echo "Test Plan: $TEST_PLAN"
      echo "Date: $(date)"
      echo "Number of Runners: $N"
      echo ""
      echo "Baseline Runtime: $baseline_runtime seconds"
      echo "Average Runtime with Noisy Neighbors: $avg_runtime seconds"
      echo "Average Performance Impact: ${avg_slowdown}% slower"
      echo "Fastest Runner: #$min_runner ($min_runtime seconds)"
      echo "Slowest Runner: #$max_runner ($max_runtime seconds)"
      
      # Add system resource statistics if available
      if [[ -f "${METRICS_DIR}/resource_usage.log" ]]; then
        echo ""
        echo "System Resource Statistics:"
        
        # Calculate average CPU usage
        local avg_cpu=$(awk -F, 'NR>1 {sum+=$2; count++} END {printf "%.2f", sum/count}' "${METRICS_DIR}/resource_usage.log")
        echo "Average CPU Usage: ${avg_cpu}%"
        
        # Calculate peak CPU usage
        local peak_cpu=$(awk -F, 'NR>1 {if ($2>max) max=$2} END {printf "%.2f", max}' "${METRICS_DIR}/resource_usage.log")
        echo "Peak CPU Usage: ${peak_cpu}%"
        
        # Calculate average memory usage in MB
        local avg_mem=$(awk -F, 'NR>1 {sum+=$3; count++} END {printf "%.2f", (sum/count)/1024}' "${METRICS_DIR}/resource_usage.log")
        echo "Average Memory Usage: ${avg_mem} MB"
        
        # Calculate peak memory usage in MB
        local peak_mem=$(awk -F, 'NR>1 {if ($3>max) max=$3} END {printf "%.2f", max/1024}' "${METRICS_DIR}/resource_usage.log")
        echo "Peak Memory Usage: ${peak_mem} MB"
      fi
    } > "${METRICS_DIR}/summary_report.txt"
    
    echo "A summary report has been saved to: ${METRICS_DIR}/summary_report.txt"
  fi

  echo "----------------------------------------------------"
  echo "Performance impact analysis complete. Detailed logs available in the $METRICS_DIR directory."
  
  # Generate visualizations
  generate_charts
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