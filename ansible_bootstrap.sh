#!/usr/bin/env bash
# ansible_bootstrap.sh  –  prompt for Tailscale auth‑key the first time it runs
# Installs: Tailscale, Git, Ansible, Avahi; clones repo; pushes pub‑key; joins tailnet.
set -euo pipefail

# ── USER CONFIG ────────────────────────────────────────────────────
REPO_URL="git@github.com:KeatonShawhan/KeysightTestAutomation.git"  # change if repo URL differs
CLONE_DIR="$HOME/KeysightTestAutomation"                            # where repo will live
KEY_FILE="host_keys.txt"                                           # inside the repo
# ───────────────────────────────────────────────────────────────────


echo "▶ Installing Tailscale via official script…"
curl -fsSL https://tailscale.com/install.sh | sudo sh

echo "▶ Installing remaining packages…"
sudo apt-get update -qq
sudo apt-get install -y jq git ansible avahi-daemon avahi-utils >/dev/null


# enable services
sudo systemctl enable --now tailscaled avahi-daemon

# ------------------------------------------------------------------
# 3. Ensure an SSH key exists (used for Git + Ansible controller auth)
# ------------------------------------------------------------------
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  echo "▶ Generating SSH key…"
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
fi
PUBKEY=$(<"$HOME/.ssh/id_ed25519.pub")
HOSTNAME=$(hostname)

# ------------------------------------------------------------------
# 4. Clone or update the scripts repo
# ------------------------------------------------------------------
if [[ -d "$CLONE_DIR/.git" ]]; then
  git -C "$CLONE_DIR" pull --quiet
else
  echo "▶ Cloning repo $REPO_URL …"
  if ! git clone --quiet "$REPO_URL" "$CLONE_DIR"; then
    cat <<EOF
❌  Clone failed.  Add this PUBLIC key as a write‑enabled deploy key
    in the repo, then rerun this script.

$PUBKEY
EOF
    exit 1
  fi
fi

cd "$CLONE_DIR"

git config user.name  "$HOSTNAME"           || true
git config user.email "${HOSTNAME}@farmslug.local" || true

# ------------------------------------------------------------------
# 5. Append this host to host_keys.txt and push
# ------------------------------------------------------------------
if ! grep -q "^${HOSTNAME}[[:space:]]" "$KEY_FILE" 2>/dev/null; then
  echo "▶ Appending this host to $KEY_FILE and pushing…"
  echo "${HOSTNAME}  ${PUBKEY}" >> "$KEY_FILE"
  git add "$KEY_FILE"
  git commit -m "add key for $HOSTNAME" --quiet
  git pull --rebase --quiet || { echo "❌ git pull failed; fix manually."; exit 1; }
  if ! git push; then
    echo "❌ git push failed — make sure this key is a WRITE deploy key in GitHub."
    exit 1
  fi
fi

# ------------------------------------------------------------------
# 6. Bring Tailscale up (prompt for reusable auth‑key once)
# ------------------------------------------------------------------
if ! tailscale status --peers=false >/dev/null 2>&1; then
  echo "▶ First‑time Tailscale login."
  read -rp "Enter your reusable Tailscale auth-key: " TS_AUTH_KEY
  sudo tailscale up --authkey "$TS_AUTH_KEY" --hostname "$HOSTNAME" --ssh --accept-routes
else
  echo "▶ Tailscale already connected."
fi

# ------------------------------------------------------------------
# 7. Install inventory helper
# ------------------------------------------------------------------
sudo install -m 0755 "$CLONE_DIR/generate_inventory.sh" /usr/local/bin/

echo "✓ Bootstrap complete on $HOSTNAME"
echo "   Next:  generate_inventory.sh && ansible-playbook …"

