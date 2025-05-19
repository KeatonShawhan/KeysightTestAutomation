---

layout: default
title: Troubleshooting
---

# Troubleshooting Guide

Resolve common issues encountered when running the **Keysight Test Automation Suite**.

---

## 1 – Connection Issues

### 1.1 Ansible can’t reach Pis

**Symptoms** – `ansible all -m ping` fails; SSH timeout.

**Solutions**

```bash
# Test basic connectivity
ping pi-node-01.yourtailnet.ts.net

# Check Tailscale status
tailscale status

# Verify SSH access
ssh pi@pi-node-01.yourtailnet.ts.net

# Restart Tailscale if required
sudo systemctl restart tailscaled
```

### 1.2 Inventory problems

**Symptom** – *No hosts matched* error.

```bash
# Regenerate inventory
generate_inventory.sh

# Inspect the file
cat ~/hosts.yml

# Test explicitly
ansible all -i ~/hosts.yml -m ping
```

---

## 2 – Test Execution Issues

### 2.1 Runner registration fails

**Symptom** – *Registration failed* in logs.

```bash
# Validate token
echo $REG_TOKEN

# Manual registration
cd ~/runner_1
./tap runner register --url https://test-automation.pw.keysight.com \
                      --registrationToken "$REG_TOKEN"

# Connectivity check
curl -I https://test-automation.pw.keysight.com
```

### 2.2 Tests don’t start

```bash
# Runner status
pgrep -f tap

# Verify test plan
ls -la ~/KeysightTestAutomation/taprunner/Baseline.TapPlan

# Check runner dirs
ls -la ~/runner_*

tail -f ~/runner_1/runner.log
```

### 2.3 Port conflicts

```bash
# Identify port consumers
ss -tulpn | grep 201

# Kill stale processes
pkill -f OPENTAP_RUNNER_SERVER_PORT

# Stop and clean
./test-scripts/runnerScript.sh stop
```

---

## 3 – Performance Issues

### 3.1 High CPU usage

```bash
top -u pi     # Live process list
htop          # Per‑core view
# Reduce runner count in playbook (e.g. runners: 2)
```

### 3.2 Out of memory

```bash
free -h
ps aux --sort=-%mem | head

# Option 1: lower concurrency
# Option 2: add swap
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

### 3.3 Disk space full

```bash
df -h
du -h ~/KeysightTestAutomation/metrics | sort -rh | head

# Automated cleanup
ansible-playbook -i ~/hosts.yml ansible/run_cleanup_metrics.yml \
  --extra-vars "days_old=3"

# Manual cleanup
./test-scripts/cleanup_metrics.sh 7
```

---

## 4 – Git Issues

### 4.1 Repository sync failures

```bash
cd ~/KeysightTestAutomation
git status
git stash
git reset --hard HEAD
git pull
sudo chown -R pi:pi ~/KeysightTestAutomation
```

### 4.2 Merge conflicts

```bash
git stash
git pull --rebase
git stash pop   # If needed
git reset --hard origin/main  # Discards local changes
```

---

## 5 – Network Issues

### 5.1 Tailscale problems

```bash
tailscale status
sudo systemctl restart tailscaled
sudo tailscale up --authkey YOUR_AUTH_KEY
cat /etc/resolv.conf
```

### 5.2 Firewall blocking

```bash
sudo ufw status
sudo ufw allow 20110:20220/tcp
# Or temporarily disable
sudo ufw disable
```

---

## 6 – Authentication Issues

### 6.1 Vault decryption fails

```bash
ansible-vault view group_vars/all/vault.yml
ansible-vault rekey group_vars/all/vault.yml

echo "your_vault_password" > ~/.vault_pass
chmod 600 ~/.vault_pass
ansible-playbook --vault-password-file ~/.vault_pass ...
```

### 6.2 SSH key problems

```bash
ssh-add -l          # List keys
ssh-add ~/.ssh/id_ed25519
ssh -v pi@pi-node-01.yourtailnet.ts.net
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519  # Regenerate if needed
```

---

## 7 – Debugging Commands

```bash
# System health
systemctl status tailscaled
df -h
free -h
top -bn1 | head -20

# Network
tailscale status
ping -c3 google.com
ss -tulpn | grep 201

# Application
pgrep -f tap
ps aux | grep ansible
journalctl -u tailscaled -n 50
tail -f /var/log/syslog

# Runner status
a cd ~/runner_1 && ./tap runner status
```

Run Ansible verbosely:

```bash
ansible-playbook -i ~/hosts.yml playbook.yml -vvv
ansible all -i ~/hosts.yml -m setup -vvv
ansible-playbook -i ~/hosts.yml playbook.yml --step
```

---

## 8 – Emergency Recovery

### Complete reset

```bash
./test-scripts/runnerScript.sh stop
sudo systemctl stop tailscaled
rm -rf ~/runner_* ~/KeysightTestAutomation/metrics/*
sudo systemctl start tailscaled
tailscale up

curl -sSL https://raw.githubusercontent.com/KeatonShawhan/KeysightTestAutomation/main/test-scripts/ansible_bootstrap.sh | bash
```

### Restore from backup

```bash
tar -xzf keysight-backup.tar.gz -C ~/
cp backup/vault.yml group_vars/all/
generate_inventory.sh
```

---

## 9 – Getting Help

### Log collection checklist

```bash
# System logs
journalctl -n 100 > system.log

# Application logs
tar -czf logs.tar.gz ~/runner_*/runner.log \
                     ~/KeysightTestAutomation/metrics/*/

# Ansible output
ansible-playbook -i ~/hosts.yml playbook.yml -vv \
                 > ansible.log 2>&1
```

| Log type | Location                            |
| -------- | ----------------------------------- |
| System   | `/var/log/syslog`, `journalctl`     |
| Runner   | `~/runner_*/runner.log`             |
| Metrics  | `~/KeysightTestAutomation/metrics/` |
| Ansible  | Terminal output / redirected file   |

---
