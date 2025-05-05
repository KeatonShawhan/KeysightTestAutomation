#!/usr/bin/env bash

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

    # Convert the CSV cpu_cores.log to a grid format in grid_data.log
    tail -n +2 "${METRICS_DIR}/cpu_cores.log" | while IFS=, read -r timestamp core0 core1 core2 core3 core4; do
      # Calculate relative time if desired
      rel_time=$(echo "$timestamp - $start_ts" | bc)
      echo "$rel_time 0 $core0"
      echo "$rel_time 1 $core1"
      echo "$rel_time 2 $core2"
      echo "$rel_time 3 $core3"
      echo "$rel_time 4 $core4"
      echo ""  # Blank line to separate blocks (scans)
    done > "${METRICS_DIR}/grid_data.log"

    
    gnuplot <<EOF
set terminal png size 1000,600
set output '$charts_dir/cpu_cores_heatmap.png'
set title 'CPU Cores Usage Heatmap'
set xlabel 'Time (seconds from start)'
set ylabel 'CPU Core'
set datafile separator ' '   # In our grid file, columns are space separated.
set view map
set cblabel 'Usage %'
set palette defined (0 'blue', 50 'green', 75 'yellow', 100 'red')
splot '${METRICS_DIR}/grid_data.log' using 1:2:3 with pm3d notitle
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
  for i in $(seq 2 "$NUM_RUNNERS"); do
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
  if (( NUM_RUNNERS > 1 )); then
    local avg_runtime=$(echo "scale=4; $total_runtime / (${NUM_RUNNERS} - 1)" | bc)
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
      echo "Number of Runners: $NUM_RUNNERS"
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


# Enhanced function to collect system resource usage during test execution
function monitor_resources() {
  local output_file="${METRICS_DIR}/resource_usage.log"

  # CSV header
  echo "timestamp,cpu_percent,memory_kb,disk_io_read_kb,disk_io_write_kb,network_rx_bytes,network_tx_bytes,load_avg" \
    > "$output_file"

  # Read the very first CPU counters
  read prev_total prev_idle < <(
    awk '/^cpu / {
      idle=$5;
      total=$2+$3+$4+$5+$6+$7+$8+$9;
      print total, idle
    }' /proc/stat
  )

  while [[ -f "${METRICS_DIR}/.monitoring_active" ]]; do
    sleep 1

    # Timestamp
    local timestamp=$(date +%s)

    # Read new CPU counters
    local total idle dtotal didle cpu_pct
    read total idle < <(
      awk '/^cpu / {
        idle=$5;
        total=$2+$3+$4+$5+$6+$7+$8+$9;
        print total, idle
      }' /proc/stat
    )

    # Compute deltas
    dtotal=$(( total  - prev_total ))
    didle =$(( idle   - prev_idle  ))
    prev_total=$total
    prev_idle =$idle

    # Avoid division by zero
    if (( dtotal > 0 )); then
      cpu_pct=$(awk -v dt="$dtotal" -v di="$didle" \
        'BEGIN { printf "%.2f", (dt - di)/dt * 100 }'
      )
    else
      cpu_pct="0.00"
    fi

    # (rest of your stats — memory, I/O, network, loadavg — unchanged)
    local memory_kb=$(awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} END {print t - a}' /proc/meminfo)
    # … disk, network, loadavg as before …

    echo "$timestamp,$cpu_pct,$memory_kb,$disk_read,$disk_write,$net_rx,$net_tx,$load_avg" \
      >> "$output_file"
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

# Function to monitor CPU usage per core (using /proc/stat deltas)
function monitor_cpu_cores() {
  local output_file="${METRICS_DIR}/cpu_cores.log"
  local num_cores
  num_cores=$(nproc)

  # build header: timestamp,core0,core1,...
  {
    printf 'timestamp'
    for i in $(seq 0 $((num_cores-1))); do
      printf ',core%s' "$i"
    done
    echo
  } > "$output_file"

  # read initial stats
  declare -A prev_total prev_idle
  while read -r line; do
    if [[ $line =~ ^cpu([0-9]+)\  ]]; then
      # fields: cpuN user nice system idle iowait irq softirq steal guest guest_nice
      read -r cpu user nice system idle iowait irq softirq steal _ _ <<<"$line"
      local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
      prev_total["${BASH_REMATCH[1]}"]=$total
      prev_idle["${BASH_REMATCH[1]}"]=$idle
    fi
  done < /proc/stat

  # now loop
  while [[ -f "${METRICS_DIR}/.monitoring_active" ]]; do
    sleep 1
    local timestamp
    timestamp=$(date +%s)
    local out_line="$timestamp"

    # second snapshot & compute delta
    while read -r line; do
      if [[ $line =~ ^cpu([0-9]+)\  ]]; then
        read -r cpu user nice system idle iowait irq softirq steal _ _ <<<"$line"
        local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
        local prev_t=${prev_total["${BASH_REMATCH[1]}"]}
        local prev_i=${prev_idle["${BASH_REMATCH[1]}"]}
        local dtotal=$((total - prev_t))
        local didle=$((idle - prev_i))
        # avoid divide-by-zero
        if (( dtotal > 0 )); then
          # usage % = (busy delta)/(total delta)*100
          local usage
          usage=$(awk -v dt="$dtotal" -v di="$didle" 'BEGIN{printf "%.2f", (dt - di)/dt*100}')
        else
          usage="0.00"
        fi
        out_line+=",${usage}"
        # store for next round
        prev_total["${BASH_REMATCH[1]}"]=$total
        prev_idle["${BASH_REMATCH[1]}"]=$idle
      fi
    done < /proc/stat

    echo "$out_line" >> "$output_file"
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

function kill_metrics(){
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
}

function start_metrics(){
  # Clean up previous metrics
  rm -rf "${METRICS_DIR}"/*.log
  mkdir -p "${METRICS_DIR}/charts"

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
}