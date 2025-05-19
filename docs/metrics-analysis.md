---

layout: default
title: Metrics & Analysis
---

# Metrics & Analysis Guide

Understand what the Keysight Test Automation Suite measures, where the data lives, and how to turn raw logs into actionable insights.

---

## What Metrics Are Collected

### 1. System Resources

* **CPU Usage** – per‑core and aggregate %
* **Memory** – total, used, available, swap
* **Disk I/O** – read / write KB s⁻¹
* **Network** – RX/TX bytes, connection states
* **Load Average** – 1‑minute load value

### 2. Test Execution

* **Runtime** – individual test durations
* **Throughput** – tests completed per time slice
* **Success / Failure** – pass / fail counts
* **Wave performance** – specific to *9 AM Monday* scenario

---

## Where Metrics Are Stored

### During Test Execution (per Pi)

```
~/KeysightTestAutomation/metrics/<scenario>_<timestamp>/
├── resource_usage.log          # System performance
├── cpu_cores.log               # Per‑core CPU stats
├── memory_detailed.log         # Memory counters
├── network_connections.log     # Netstat snapshot
└── runner*_metrics.log         # Execution data per runner
```

### After Aggregation (controller)

```
/tmp/metrics_dump/<timestamp>/
├── <hostname>_resource_usage.log   # Node‑level metrics
└── influxdump_<timestamp>.lp       # InfluxDB line protocol
```

---

## Understanding the Data

### Log Formats

**resource\_usage.log**

```csv
timestamp,cpu_percent,memory_kb,disk_io_read_kb,disk_io_write_kb,network_rx_bytes,network_tx_bytes,load_avg
1638360000,45.2,2048576,1024,512,1048576,524288,1.25
```

**runner metrics**

```
runner_id=1,wave=wave1,start=1638360000.123,end=1638360045.456,runtime=45.333
```

**InfluxDB LP**

```
pi_resources,host=pi-node-01 cpu_percent=45.2,memory_kb=2048576,disk_io_read_kb=1024,disk_io_write_kb=512,network_rx_bytes=1048576,network_tx_bytes=524288,load_avg=1.25 1638360000000000000
```

---

## Automatic Analysis

If **gnuplot** is installed, charts are built automatically and saved to `charts/` inside each scenario folder:

* CPU usage over time
* Memory utilisation trends
* Load‑average plots
* Network traffic graphs
* CPU‑core heatmaps

A text **summary report** is also generated, for example:

```
Test Plan:           Baseline.TapPlan
Date:                2024‑01‑15 14:30:22
Runners:             5

Baseline Runtime:    45.234 s
Avg Runtime w/Load:  47.456 s
Impact:              4.92 % slower

Fastest Runner:      #2 (46.123 s)
Slowest Runner:      #4 (48.789 s)

System Resources
  Avg CPU Usage:     68.5 %
  Peak CPU Usage:    89.2 %
  Avg Memory Usage:  3.2 GB
  Peak Memory Usage: 4.1 GB
```

---

## Manual Analysis

### Using Standard Tools

```bash
# Plot CPU usage with gnuplot
gnuplot -e "set terminal png; set output 'cpu.png'; \
           plot 'resource_usage.log' using 1:2 with lines"

# Average CPU %
awk -F',' 'NR>1 {sum+=$2} END {print sum/NR}' resource_usage.log

# Peak memory (MB)
awk -F',' 'NR>1 {if($3>max) max=$3} END {print max/1024 " MB"}' resource_usage.log
```

## Troubleshooting Performance Issues

| Symptom             | Checks & Remedies                                                        |
| ------------------- | ------------------------------------------------------------------------ |
| **High CPU**        | Check runner count, look for runaway processes, inspect heavy test steps |
| **Memory pressure** | Watch swap, look for leaks, cap runners                                  |
| **Network issues**  | Inspect `TIME_WAIT`, test bandwidth, check packet loss                   |
| **Disk I/O waits**  | Verify free space, consider faster storage, reduce logging volume        |

---

## Best Practices

1. **Collect baselines** before experimental runs.
2. **Repeat tests** for statistical confidence.
3. **Document conditions**: runner count, plan version, hardware.
4. **Archive results** for long‑term trend analysis.
5. **Clean up** raw logs periodically – keep summaries longer.

---
