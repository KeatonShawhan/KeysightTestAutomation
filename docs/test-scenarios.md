---

layout: default
title: Test Scenarios
---

# Test Scenarios Guide

The Keysight Test Automation Suite ships with **five** ready‑made scenarios that target common performance and reliability questions. Use them as‑is or customise them to meet your lab’s needs.

---

## 1. 9 AM Monday Scenario

### Purpose 
Peak‑load simulation that mirrors the Monday‑morning login surge.

### Overview

Replicates the rapid increase in user activity when teams return to work, using optional login simulation and wave‑based execution.

### Key Features

* **Wave‑based execution** – three waves at 20 %, 30 %, 50 % of runners
* **Staggered timing** – inter‑wave delay drops 1 s → 0.5 s → 0.25 s
* **Login simulation** – optional Cypress‑driven authentication tests
* **Random runner selection** – each wave chooses a different subset

### Configuration example

```yaml
# ansible/run_9am_monday.yml
vars:
  runners: 5                       # Total runners
  test_plan: /home/pi/Baseline.TapPlan
  reg_token: "{{ vault_token }}"
```

### Usage

```bash
# Basic execution
ansible-playbook -i ~/hosts.yml ansible/run_9am_monday.yml

# Custom parameters
ansible-playbook -i ~/hosts.yml ansible/run_9am_monday.yml \
  --extra-vars "runners=10 test_plan=/custom/Morning.TapPlan"
```

**Script‑level call:**

```bash
./test-scripts/9am_monday_login.sh 5 Baseline.TapPlan TOKEN true 3
# 5 runners, login simulation, 3 retries
```

### Expected outcomes

* Progressive load charts
* Per‑wave performance metrics
* Login success / failure statistics (if enabled)
* Resource‑utilisation trend during peak load

---

## 2. Active Lab Scenario

### Purpose 
Continuous activity benchmark mimicking a busy lab.

### Overview

Runs tests non‑stop for a set duration with randomised gaps to gauge sustained‑load behaviour.

### Key Features

* **Continuous execution** – default 300 s duration
* **Random intervals** – 5–30 s delay between runs
* **Parallel runners** – each Pi acts independently
* **Cumulative metrics** – total run count and per‑runner averages

### Configuration example

```yaml
# ansible/run_active_lab.yml
vars:
  runners: 3                    # Concurrent runners
  simulation_time: 300          # Seconds to run
  test_plan: /home/pi/Baseline.TapPlan
  reg_token: "{{ vault_token }}"
```

### Usage

```bash
# Standard
ansible-playbook -i ~/hosts.yml ansible/run_active_lab.yml

# Extended
ansible-playbook -i ~/hosts.yml ansible/run_active_lab.yml \
  --extra-vars "simulation_time=600 runners=8"
```

**Direct script:**

```bash
./test-scripts/active_lab.sh 5 120 Baseline.TapPlan TOKEN
```

### Metrics collected

* Runs per runner
* Average execution time
* Aggregate runtime
* Resource footprints under sustained load

---

## 3. Network Outage Scenario

### Purpose 
Measure resilience and recovery following network disruption.

### Overview

Pauses runners mid‑execution to emulate a connectivity loss, then resumes to track post‑outage performance.

### Key Features

* **Controlled disruption** – pause after configurable runtime
* **Adjustable outage** – set outage length
* **Recovery focus** – compare pre‑/post‑outage metrics
* **Impact analysis** – error rates and throughput changes

### Configuration example

```yaml
# ansible/run_network_outage.yml
vars:
  runners: 3
  runtime_before_outage: 300    # Seconds before outage
  outage_duration: 60           # Outage length
  test_plan: /home/pi/Baseline.TapPlan
  reg_token: "{{ vault_token }}"
```

### Usage

```bash
ansible-playbook -i ~/hosts.yml ansible/run_network_outage.yml

# Custom
ansible-playbook -i ~/hosts.yml ansible/run_network_outage.yml \
  --extra-vars "runtime_before_outage=180 outage_duration=30"
```

**Script‑level call:**

```bash
./test-scripts/network_outage.sh 5 300 60 Baseline.TapPlan TOKEN
```

### Implementation details

The script signals each TAP process with `SIGSTOP` (pause) and `SIGCONT` (resume).

### Resilience metrics

* Throughput during outage
* Recovery time
* Error rates before / during / after
* System stability indicators

---

## 4. Noisy Neighbors Scenario

### Purpose 
Assess resource contention when multiple runners share a host.

### Overview

Calculates the “noisy‑neighbor” effect by comparing single‑runner baseline performance to concurrent runs.

### Key Features

* **Baseline+concurrency** – phase‑based measurement
* **Performance comparison** – slowdown percentages
* **Resource contention** – CPU, memory, I/O impact

### Execution (script only)

```bash
# Minimum 2 runners (1 baseline + rest concurrent)
./test-scripts/noisyNeighbors.sh 5 Baseline.TapPlan TOKEN
```

### Phases

1. **Baseline** – single runner
2. **Concurrent** – remaining runners start
3. **Analysis** – compute impact

### Key metrics

* Baseline vs concurrent runtime
* Average slowdown
* Resource utilisation profiles

---

## 5. Cleanup Scenario

### Purpose 
Automate log/metrics removal to preserve disk space.

### Overview

Deletes test artifacts older than a threshold across all nodes.

### Key Features

* **Configurable retention** – default 7 days
* **Safe deletion** – targets only test‑generated data
* **Parallel execution** – runs on every node
* **Summary report** – files removed & space reclaimed

### Configuration example

```yaml
# ansible/run_cleanup_metrics.yml
vars:
  days_old: 7
  repo_dir: ~/KeysightTestAutomation
  cleanup_script: test-scripts/cleanup_metrics.sh
```

### Usage

```bash
ansible-playbook -i ~/hosts.yml ansible/run_cleanup_metrics.yml

# Custom retention
ansible-playbook -i ~/hosts.yml ansible/run_cleanup_metrics.yml \
  --extra-vars "days_old=14"
```

**Direct script:**

```bash
./test-scripts/cleanup_metrics.sh 7
```

### Cleanup scope

* Execution logs
* Metrics files
* Generated charts
* Temporary analysis artifacts

---

## Scenario Comparison

| Scenario        | Purpose                       | Typical Duration | Complexity | Key Metrics                   |
| --------------- | ----------------------------- | ---------------- | ---------- | ----------------------------- |
| 9 AM Monday     | Peak‑load simulation          | 5–10 min         | Medium     | Wave performance, login rates |
| Active Lab      | Sustained activity            | 5–60 min         | Low        | Continuous load, run count    |
| Network Outage  | Resilience testing            | 10–15 min        | High       | Recovery time, error rates    |
| Noisy Neighbors | Resource‑competition analysis | 10–20 min        | Medium     | Baseline vs concurrent perf   |
| Cleanup         | Maintenance / housekeeping    | < 5 min          | Low        | Storage reclaimed             |

---

## Custom Scenario Development

### Steps to create your own

1. **Copy a template** – duplicate an existing script.
2. **Modify logic** – adjust execution pattern, timing, etc.
3. **Define metrics** – decide what to measure.
4. **Add playbook** – automate with Ansible if desired.

### Example skeleton

```bash
#!/usr/bin/env bash
# custom_weekend.sh – Weekend maintenance simulation

MAINTENANCE_WINDOW=7200  # 2 hours
LOW_ACTIVITY_INTERVAL=60 # 1 minute between tests

# Custom test logic goes here
```

---
