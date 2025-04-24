#!/usr/bin/env bash
# ansible_bootstrap.sh
# ---------------------------------------------------------------
# Sets up a brand-new Raspberry Pi for Tailscale-based Ansible:
#   • Installs Tailscale (official script), Ansible, Git, Avahi
#   • Joins the tailnet (prompts once for a reusable auth-key)
#   • Advertises tag:farmslug (adds it later with `tailscale set`
#     if the node was already connected)
#   • Clones your automation repo and deploys generate_inventory.sh
#
# Usage on the Pi (as user pi):
#   curl -sSL https://raw.githubusercontent.com/KeatonShawhan/KeysightTestAutomation/main/ansible_bootstrap.sh | bash
# ----------------------------------------------------------------

set -euo pipefail

REPO_URL="https://github.com/KeatonShawhan/KeysightTestAutomation.git"
CLONE_DIR="$HOME/KeysightTestAutomation"

echo "▶ Installing Tailscale via official script…"
curl -fsSL https://tailscale.com/install.sh | sudo sh

echo "▶ Installing Ansible, Git, Avahi, jq…"
sudo apt-get update -qq
sudo apt-get install -y ansible git jq avahi-daemon avahi-utils >/dev/null
sudo systemctl enable --now tailscaled avahi-daemon
echo "▶ Installing other runner prerequisites (expect, unzip, iproute2)…"
sudo apt-get install -y expect unzip iproute2 curl >/dev/null

echo "▶ Ensuring dotnet executable is on the global PATH…"
DOTNET_BIN="$HOME/.dotnet/dotnet"
if [[ -x "$DOTNET_BIN" ]]; then
  sudo ln -sf "$DOTNET_BIN" /usr/local/bin/dotnet
else
  echo "⚠ dotnet not found in $DOTNET_BIN; skipping symlink."
fi

HOSTNAME=$(hostname)
# self-SSH enable
# ensure SSH key exists
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
fi

AUTH="$HOME/.ssh/authorized_keys"
mkdir -p ~/.ssh && touch "$AUTH" && chmod 600 "$AUTH"
grep -qxF "$(cat ~/.ssh/id_ed25519.pub)" "$AUTH" || \
  cat ~/.ssh/id_ed25519.pub >> "$AUTH"

# ── Tailscale join or tag update ────────────────────────────────
if ! tailscale status --peers=false >/dev/null 2>&1; then
  echo
  read -rp "Enter reusable Tailscale auth-key: " TS_KEY
  sudo tailscale up \
       --authkey "$TS_KEY" \
       --hostname "$HOSTNAME" \
       --ssh \
       --accept-routes \
       --advertise-tags=tag:farmslug
else
  if ! tailscale status --json | jq -e '.Self.Tags[]? | select(.=="tag:farmslug")' >/dev/null; then
    echo "▶ Adding tag:farmslug to existing node…"
    sudo tailscale set --advertise-tags=tag:farmslug
  else
    echo "▶ Tailscale already connected with tag:farmslug."
  fi
fi


# ── Ensure /etc/resolv.conf keeps Tailscale's DNS entry ─────────
echo "▶ Forcing Tailscale nameserver to stay in /etc/resolv.conf …"

# 1. Re-apply DNS settings (safe even if already set)
sudo tailscale set --accept-dns=true

# 2. Make resolv.conf immutable so nothing overwrites it
sudo chattr +i /etc/resolv.conf || {
  echo "⚠ Could not set +i attribute; check filesystem type."
}

echo "✓ DNS pinned.  If you ever need to edit resolv.conf manually:"
echo "  sudo chattr -i /etc/resolv.conf"


# ── Deploy inventory helper ─────────────────────────────────────
sudo install -m 0755 "$CLONE_DIR/generate_inventory.sh" /usr/local/bin/


# ── Disable host-key prompt for all Ansible runs ────────────────
echo "▶ Creating ~/.ansible.cfg (host_key_checking = False)…"
cat > "$HOME/.ansible.cfg" <<'EOF'
[defaults]
host_key_checking = False
EOF
chmod 600 "$HOME/.ansible.cfg"

echo "✓ Bootstrap complete on $HOSTNAME"
echo "  Next steps:"
echo "    1) generate_inventory.sh            # build ~/hosts.yml"
echo "    2) ansible-playbook -i ~/hosts.yml <playbook>.yml …"

