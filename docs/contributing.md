---

layout: default
title: Contributing
---

# Contributing Guide

We welcome community participation in improving the **Keysight Test Automation Suite**. This document explains where and how you can help.

---

## 1 – Getting Started

### 1.1 Prerequisites

* Bash & Ansible familiarity
* Raspberry Pi hardware for real‑world testing
* Basic Git workflow knowledge
* Tailscale account for mesh networking

### 1.2 Local Development Setup

1. **Fork** the repository on GitHub.
2. **Clone** your fork:

   ```bash
   git clone https://github.com/<your-username>/KeysightTestAutomation.git
   cd KeysightTestAutomation
   ```
3. Provision ≥ 2 Raspberry Pis and connect them to your tailnet.
4. Run the bootstrap script on each Pi to install dependencies:

   ```bash
   curl -sSL https://raw.githubusercontent.com/KeatonShawhan/KeysightTestAutomation/main/test-scripts/ansible_bootstrap.sh | bash
   ```

---

## 2 – Types of Contributions

| Type             | Typical Actions                                            |
| ---------------- | ---------------------------------------------------------- |
| **Bug report**   | File an issue with logs & reproduction steps               |
| **Feature idea** | Open a feature request describing problem & use‑case       |
| **Code**         | Add scenarios, playbooks, scripts, or metrics improvements |
| **Docs**         | Fix typos, clarify steps, translate, add examples          |

### 2.1 Bug Reports

Before opening an issue:

* Search existing issues.
* Reproduce on a clean environment.
* Gather logs (`runner.log`, `resource_usage.log`, etc.).

Include:

* Descriptive title.
* Exact reproduction steps.
* Environment details (Pi model, OS, tailnet setup).
* Relevant logs / screenshots.

### 2.2 Feature Requests

A strong request should contain:

* Problem description.
* Proposed approach or alternatives.
* Expected benefits & use‑cases.
* Rough complexity estimate (if known).

### 2.3 Code Contributions

#### New Test Scenarios

1. Place script in `test-scripts/` named `your_scenario.sh`.
2. Use metrics helpers via `metric_tools.sh`.
3. Create matching Ansible playbook in `ansible/`.
4. Update `docs/test-scenarios.md`.

Example skeleton:

```bash
#!/usr/bin/env bash
# weekend_maintenance.sh – Low‑activity weekend scenario
set -euo pipefail
SCRIPT_DIR="$(dirname "$0")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SESSION_FOLDER="${REPO_ROOT}/metrics/weekend_$(date +%s)"
source "${SCRIPT_DIR}/metric_tools.sh"

start_metrics "$SESSION_FOLDER"
# … scenario logic …
generate_charts "$SESSION_FOLDER"
kill_metrics "$SESSION_FOLDER"
```

#### Ansible Playbooks

* Follow existing async + git‑management pattern.
* Handle errors (`failed_when`, `ignore_errors`).
* Include variable docs in comments.
* Test on multi‑node clusters.

#### Metrics Extensions

* Integrate with `metric_tools.sh`.
* Generate gnuplot charts.
* Ensure InfluxDB LP export compatibility.
* Keep overhead low (< 5 % CPU).

### 2.4 Documentation Improvements

* Fix typos or unclear descriptions.
* Add real‑world examples / screenshots.
* Update outdated sections.
* Provide translations if fluent.

---

## 3 – Development Process

### 3.1 Workflow

1. Create a feature branch: `git checkout -b feat/my-change`.
2. Make focused commits with clear messages.
3. Test thoroughly on physical Pis.
4. Update docs & examples.
5. Push and open a Pull Request (PR).

### 3.2 Commit Guidelines

* Use imperative, descriptive titles.
* Reference issues (`Fixes #123`).
* Keep commits atomic.
* Sign commits if your organisation requires.

**Good examples**

```
Add weekend maintenance scenario

Provides low‑activity workload with configurable
intervals and durations. Fixes #123.
```

### 3.3 Testing Checklist

* Run existing scenarios – ensure no regressions.
* Execute new scenario on multiple Pis.
* Verify playbooks across environments.
* Ensure docs render correctly (`jekyll serve`).

---

## 4 – Code Style & Quality

### 4.1 Bash Scripts

* Shebang `#!/usr/bin/env bash`.
* `set -euo pipefail`.
* Quote variables.
* Use descriptive names.
* Provide error handling & logging.

### 4.2 Ansible Playbooks

* Consistent YAML indentation.
* Name each task.
* Idempotent operations.
* Use variables, not hard‑coded paths.
* Fail gracefully.

### 4.3 Documentation

* Clear, concise language.
* Practical examples.
* Update table of contents if needed.

---

## 5 – Security Considerations

* **Never** commit secrets.
* Store tokens in **Ansible Vault**.
* Add secret files to `.gitignore`.
* Document any new network ports or firewall rules.

---

## 6 – Release Process

* Semantic versioning **MAJOR.MINOR.PATCH**.
* Maintain `CHANGELOG.md` with new features, fixes, breaking changes.
* Provide migration notes if applicable.

---

## 7 – Community Guidelines

| Aspect        | Expectations                                    |
| ------------- | ----------------------------------------------- |
| Communication | Be respectful, professional, and supportive     |
| Issues        | Label appropriately, respond promptly           |
| Reviews       | Offer constructive feedback, test when possible |

Active maintainers:

* **@tbd** 

Significant contributors are listed in release notes and may be invited as maintainers.

---

## 8 – Getting Support

First consult key documentation:

* **[Getting Started](docs/getting-started.html)**
* **[Architecture](docs/architecture.html)**
* **[Troubleshooting](docs/troubleshooting.html)**

For further help:

* **GitHub Discussions** – questions & ideas
* **GitHub Issues** – bug reports & feature requests
* **Pull Requests** – code collaboration

---

By contributing you agree your work will be released under the project’s license.

**Thank you for helping make testing faster and more reliable for everyone!**
