#!/usr/bin/env bash
# ansible_bootstrap.sh  –  uses Tailscale SSH; no host_keys.txt needed
set -euo pipefail

REPO_URL="https://github.com/KeatonShawhan/KeysightTestAutomation.git"
CLONE_DIR="$HOME/KeysightTestAutomation"

echo "▶ Install Tailscale, Ansible, Git, Avahi…"
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo apt-get update -qq
sudo apt-get install -y git ansible jq avahi-daemon avahi-utils >/dev/null
sudo systemctl enable --now tailscaled avahi-daemon

HOSTNAME=$(hostname)

# -- Join tailnet (prompt once) ------------------------------------
if ! tailscale status --peers=false >/dev/null 2>&1; then
  read -rp "Enter reusable Tailscale auth-key: " TS_KEY
  sudo tailscale up --authkey "$TS_KEY" \
       --hostname "$HOSTNAME" \
       --ssh \
       --advertise-tags=tag:farmslug
else
  echo "▶ Tailscale already connected."
fi

# -- Pull or clone scripts repo ------------------------------------
if [[ -d "$CLONE_DIR/.git" ]]; then
  git -C "$CLONE_DIR" pull --quiet
else
  git clone --quiet "$REPO_URL" "$CLONE_DIR"
fi

# -- Install inventory helper -------------------------------------
sudo install -m0755 "$CLONE_DIR/generate_inventory.sh" /usr/local/bin/

echo "✓ Bootstrap finished on $HOSTNAME"
echo "  Next:  generate_inventory.sh && ansible-playbook …"

