---

layout: default
title: Architecture
---

# System Architecture

This document offers a comprehensive look at the **Keysight Test Automation Suite**—its tiers, component interactions, data paths, and deployment patterns.

---

## High‑Level Architecture

The platform is split into **three** logical tiers:

| Tier          | Core Components                                                        | Primary Responsibilities                       |
| ------------- | ---------------------------------------------------------------------- | ---------------------------------------------- |
| **Control**   | • Ansible controller  <br>• Dynamic inventory <br>• Metrics aggregator | Orchestration, discovery, and reporting        |
| **Execution** | • Raspberry Pi cluster <br>• OpenTAP runners <br>• Resource monitors   | Distributed test execution and local telemetry |
| **Data**      | • Local metrics stores <br>• Central aggregator <br>• Export pipelines | Persistence, consolidation, and visualisation  |

---

### Control Tier

* **Ansible Controller** – orchestrates playbooks and coordinates execution.
* **Inventory Management** – uses Tailscale tags for node discovery.
* **Metrics Aggregation** – collects and merges all node‑level telemetry.

### Execution Tier

* **Raspberry Pi Nodes** – ARM64 hosts that run OpenTAP.
* **OpenTAP Runners** – isolated engines launched per node.
* **Resource Monitoring** – lightweight daemons capturing system metrics.

### Data Tier

* **Local Storage** – per‑node CSV and line‑protocol dumps.
* **Central Cache** – controller consolidates data.
* **Export Formats** – InfluxDB LP, CSV, Grafana‑ready charts.

---

## Component Details

### Ansible Controller

|                     | Description                                                                      |
| ------------------- | -------------------------------------------------------------------------------- |
| **Role**            | Central orchestration hub                                                        |
| **Key Tasks**       | Execute playbooks, sync git, aggregate metrics, manage secrets                   |
| **Important Files** | `ansible/run_*.yml`, `ansible/generate_inventory.sh`, `group_vars/all/vault.yml` |

### Raspberry Pi Nodes

|                | Details                                 |
| -------------- | --------------------------------------- |
| **Hardware**   | Pi 4 (8 GB+ recommended)                |
| **OS**         | Ubuntu/Debian aarch64                   |
| **Networking** | Tailscale mesh; MagicDNS hostnames      |
| **Services**   | OpenTAP runners, resource monitors, SSH |

### OpenTAP Runners

|               | Details                                          |
| ------------- | ------------------------------------------------ |
| **Ports**     | 20110 – 20220 (unique per runner)                |
| **Isolation** | Separate working dirs & configs                  |
| **Lifecycle** | Template‑driven deploy, auto register/deregister |
| **Metrics**   | Per‑runner CPU, mem, exec times                  |

---

## Network Architecture

### Tailscale Mesh

* **Zero‑config** overlay network with automatic encryption.
* **MagicDNS** allows nodes to resolve `<hostname>.ts.net`.
* **Tags** (e.g. `tag:farmslug`) group execution hosts.

### Port Allocation

| Service             | Port(s)     | Purpose                  |
| ------------------- | ----------- | ------------------------ |
| OpenTAP Runner      | 20110‑20220 | Test execution endpoints |
| SSH                 | 22          | Ansible connectivity     |
| Tailscale WireGuard | 41641       | Mesh traffic             |

---

## Data Flow

### Test‑Execution Sequence

1. **Initiate** – controller starts playbook.
2. **Prepare** – nodes stop existing runners and pull latest code.
3. **Deploy** – new runners spawn and register.
4. **Execute** – scenario logic drives tests.
5. **Collect** – nodes stream metrics locally.
6. **Aggregate** – controller gathers all data.
7. **Report** – consolidated summaries & visuals.

### Metrics Flow (Conceptual)

```text
┌───────────────┐    ┌───────────────┐    ┌───────────────┐
│  Pi Node 1    │    │  Pi Node 2    │    │  Pi Node N    │
│               │    │               │    │               │
│ RunnerMetrics │    │ RunnerMetrics │    │ RunnerMetrics │
│ SystemMetrics │    │ SystemMetrics │    │ SystemMetrics │
└──────┬────────┘    └──────┬────────┘    └──────┬────────┘
       │                     │                     │
       └───────────┬─────────┴───────────┬─────────┘
                   ▼                     
            ┌──────────────────┐
            │  Ansible         │
            │  Controller      │
            │ AggregatedMetrics│
            │  InfluxDBExport  │
            └──────────────────┘
```

---

## Security Architecture

| Aspect              | Implementation                                                           |
| ------------------- | ------------------------------------------------------------------------ |
| **SSH Keys**        | Ed25519; distributed by bootstrap; hostkey checking disabled within mesh |
| **Secrets Storage** | Ansible Vault (tokens, API keys)                                         |
| **Mesh Security**   | Tailscale ACLs, device auth, end‑to‑end encryption                       |
| **Isolation**       | Port scoping; per‑runner processes                                       |

---

## Deployment Patterns

### Single Controller / Multi‑Node

Standard setup: one controller and many Pis on a shared tailnet.

### Multi‑Controller

For scale or redundancy; controllers share inventory and balance workload.

### Hybrid Cloud

Mix on‑prem Pis with cloud runners; connect via VPN or shared tailnet.

---

## Scalability & Resource Management

* **Horizontal scale**: add nodes → inventory auto‑updates.
* **Runner limits**: bound per‑node by available RAM / CPU.
* **Automatic cleanup**: scheduled removal of old metrics.

---



## Monitoring & Observability

### System Metrics

* CPU (per‑core & total)
* Memory usage & pressure
* Disk I/O rates
* Network RX/TX

### Application Metrics

* Test durations & status
* Runner health
* Queue depths
* Failure counts

### Visualisation

* **Real‑time** dashboards via Grafana.
* **Historical** trend analysis for capacity planning.

---

## Failure Modes & Recovery

| Category     | Examples                   | Recovery Tactics                |
| ------------ | -------------------------- | ------------------------------- |
| **Network**  | Partition, DNS failure     | Auto‑reconnect, manual reboot   |
| **Resource** | OOM, disk full             | Auto‑cleanup, scale‑out         |
| **Service**  | Runner crash, token expiry | Supervisor restart, re‑register |

---
