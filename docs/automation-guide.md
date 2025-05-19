---

layout: default
title: Automation Guide
---

# Ansible Automation Guide

Use Ansible to orchestrate and streamline test execution across your Raspberry Pi cluster.

---

## Overview

Ansible automates the entire workflow:

* **Inventory management** – discovers Pi nodes via Tailscale tags.
* **Parallel execution** – runs tests across multiple nodes simultaneously.
* **Metrics aggregation** – collects and merges performance data.
* **Lifecycle handling** – manages setup, execution, and cleanup.

---

## Inventory Management

Generate a fresh inventory of all Pis tagged **`farmslug`**:

```bash
# Creates ~/hosts.yml
./generate_inventory.sh
```

---

## Available Playbooks

### 1. 9 AM Monday Scenario

```bash
ansible-playbook -i ~/hosts.yml ansible/run_9am_monday.yml \
  --extra-vars "runners=3 reg_token=YOUR_TOKEN"
```

*Simulates peak‑morning load with wave‑based execution.*

### 2. Active Lab Scenario

```bash
ansible-playbook -i ~/hosts.yml ansible/run_active_lab.yml \
  --extra-vars "simulation_time=300 runners=3"
```

*Continuous testing with random intervals between runs.*

### 3. Network Outage Scenario

```bash
ansible-playbook -i ~/hosts.yml ansible/run_network_outage.yml \
  --extra-vars "runtime_before_outage=300 outage_duration=60"
```

*Pauses runners mid‑execution to test resilience.*

### 4. Cleanup

```bash
ansible-playbook -i ~/hosts.yml ansible/run_cleanup_metrics.yml \
  --extra-vars "days_old=7"
```

*Removes old test metrics on all nodes.*

---

## Configuration

### Ansible Vault for Secrets

Store sensitive data securely:

```bash
# Create an encrypted vault
ansible-vault create group_vars/all/vault.yml
```

In the editor:

```yaml
vault_reg_token: "your-registration-token"
```

Reference in playbooks:

```yaml
auth_token: "{{ vault_reg_token }}"
```

### SSH Configuration

Mesh connectivity:

```ini
# ~/.ssh/config
Host *.ts.net
    User pi
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
```

---

## How It Works

1. **Git management** – stashes local changes and pulls the latest code.
2. **Async execution** – launches test scripts on each node.
3. **Progress monitoring** – waits for tests to complete.
4. **Metrics collection** – fetches logs and metrics from every node.
5. **Aggregation** – consolidates data into InfluxDB‑compatible output.

---

## Troubleshooting

* **Ping all nodes**:

  ```bash
  ansible all -i ~/hosts.yml -m ping
  ```
* **Verbose run**:

  ```bash
  ansible-playbook -i ~/hosts.yml playbook.yml -v
  ```
* **Single‑node test**:

  ```bash
  ansible-playbook -i ~/hosts.yml playbook.yml --limit pi-node-01
  ```

---

## Best Practices

* Always verify connectivity before launching large runs.
* Store every secret in **Ansible Vault**.
* Start with a small runner count to validate changes.
* Monitor CPU, memory, and disk during execution.
* Rotate and refresh registration tokens regularly.

---
