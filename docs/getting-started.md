---

layout: default
title: Getting Started
---

# Getting Started Guide

This guide will help you set up and run your first test with the Keysight Test Automation Suite.

## Prerequisites

### System Requirements

* **Raspberry Pi 4** (recommended) or any ARM64 system
* **Ubuntu/Debian‑based OS** with `systemd`
* **8 GB RAM** or more for optimal performance
* **Network connectivity** for Tailscale and package downloads

### Required Software

Although the bootstrap script installs most dependencies, ensure the control and target nodes have:

* `curl` or `wget` for downloading files
* `sudo` privileges for system configuration
* SSH access between control and runner nodes

### Accounts

* **Tailscale** account with admin rights
* **Keysight Test Automation Suite** registration token
* **GitHub** account for repository access

## Installation

### Step 1 – Initial Setup (control machine)

```bash
git clone https://github.com/KeatonShawhan/KeysightTestAutomation.git
cd KeysightTestAutomation
```

### Step 2 – Install ```node_modules```
Navigate to ```KeysightTestAutomation/ks8500-auth-service``` and make sure to run ```npm install```.

### Step 3 – Bootstrap Raspberry Pi nodes

Run the bootstrap script on **each** Raspberry Pi that will participate in testing:

```bash
# On each Raspberry Pi
curl -sSL https://raw.githubusercontent.com/KeatonShawhan/KeysightTestAutomation/main/test-scripts/ansible_bootstrap.sh | bash
```

The script will:

* Install **Tailscale** and join the Pi to your tailnet
* Install **Ansible**, **Git**, and other dependencies
* Install the **.NET** runtime required by **OpenTAP**
* Configure password‑less **SSH** keys
* Set up **MagicDNS** entries
* Clone the automation repository

### Step 4 – Generate the Ansible inventory (control machine)

```bash
# Generates ~/hosts.yml with all “farmslug”-tagged nodes
./generate_inventory.sh
```

### Step 5 – Configure test plans

Place your `.TapPlan` files in the `taprunner/` directory:

```bash
ls taprunner/
# Baseline.TapPlan  Instruments.xml  …
```

## Running Your First Test

### Simple execution

```bash
# Run the “9 AM Monday” scenario with 3 runners
ansible-playbook -i ~/hosts.yml ansible/run_9am_monday.yml \
  --extra-vars "runners=3 reg_token=YOUR_TOKEN_HERE"
```

### What to expect

1. **Setup phase** – existing runners are stopped; new ones are started.
2. **Execution phase** – tests run in waves with staggered timing.
3. **Metrics collection** – performance data is gathered from every node.
4. **Cleanup phase** – runners stop and results are aggregated.

### Viewing results

```bash
# Results are stored under /tmp/metrics_dump/ on the control machine
ls /tmp/metrics_dump/
# e.g. 20241201_143022

# Display aggregated metrics
cat /tmp/metrics_dump/20241201_143022/influxdump_20241201_143045.lp
```

#### Metrics available

* **Resource utilisation** – CPU, memory, disk I/O, network traffic
* **Execution times** – per‑runner performance metrics
* **System load** – per‑core CPU usage and load averages
* **Network connections** – connection‑state monitoring

## Configuration Options

### Customising test parameters

Edit variables in the playbook:

```yaml
# ansible/run_9am_monday.yml
vars:
  runners: 5                         # Number of test runners
  test_plan: /custom/path.TapPlan    # Custom test plan
  reg_token: "{{ vault_token }}"     # Token stored in Ansible Vault
```

### Environment‑specific settings

```bash
mkdir -p host_vars
```

```yaml
# host_vars/pi-node-01.yml
ansible_python_interpreter: /usr/bin/python3
custom_test_path: /opt/specialized/tests
```

### Common configuration

#### Ansible Vault

```bash
ansible-vault create group_vars/all/vault.yml
```

Add your secrets in the editor:

```yaml
vault_reg_token: "your-actual-token-here"
vault_api_key: "your-api-key"
```

#### Customising scenarios

```bash
cp test-scripts/9am_monday.sh test-scripts/custom_scenario.sh
# Edit wave timing, runner counts, etc.
```

## Troubleshooting

### 1 – Tailscale connection problems

```bash
tailscale status
sudo systemctl restart tailscaled
```

### 2 – Ansible connection failures

```bash
ansible all -i ~/hosts.yml -m ping
ssh-add -l
```

### 3 – Runner registration issues

```bash
./tap runner register --url https://test-automation.pw.keysight.com \
                      --registrationToken YOUR_TOKEN
curl -I https://test-automation.pw.keysight.com
```

### Debug mode

```bash
ansible-playbook -i ~/hosts.yml ansible/run_9am_monday.yml -vvv
tail -f /var/log/syslog   # On each Pi
```

## Verification Checklist

* All Pis appear in **inventory** with correct hostnames
* **SSH** connectivity works (`ansible all -m ping`)
* **Tailscale** mesh networking is operational
* Test plans are accessible from runner directories
* Registration tokens are valid
* Enough disk space exists for metrics
* Time synchronisation (NTP) is enabled on all nodes

## Next Steps

* **Explore test scenarios** – see the *Test Scenarios Guide*.
* **Deep dive into architecture** – understand how the components communicate.
* **Advanced automation** – master Ansible playbooks and roles.
* **Metrics analysis** – ingest performance data into Grafana or InfluxDB.

### Pro tips

* **Start small** – begin with 2–3 runners before scaling up.
* **Monitor resources** – watch CPU, memory, and I/O on each Pi.
* **Version control** – commit changes to test plans and config files.
* **Backups** – keep copies of your Tailscale keys and Ansible Vault.
* **Log everything** – enable verbose logging to simplify debugging.

---
