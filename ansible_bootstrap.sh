#!/usr/bin/env bash
# ansible_bootstrap.sh  –  prompt for Tailscale auth-key first time
set -euo pipefail

# ---- CONFIG ---------------------------------------------------------
REPO_URL="git@github.com:<ORG>/<REPO>.git"   # CHANGE to your repo
CLONE_DIR="$HOME/farmslug-repo"
KEY_FILE="host_keys.txt"
# --------------------------------------------------------------------

echo "▶ Installing core packages (tailscale, ansible, git, avahi)…"
sudo apt-get update -qq
sudo apt-get install -y tailscale jq git ansible avahi-daemon avahi-utils >/dev/null

echo "▶ Enabling required services..."
sudo systemctl enable --now avahi-daemon tailscaled

# -------- SSH key for Git + Ansible control -------------------------
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  echo "▶ Generating SSH key…"
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
fi
PUBKEY=$(<"$HOME/.ssh/id_ed25519.pub")
HOSTNAME=$(hostname)

# -------- Clone or pull repo ----------------------------------------
if [[ -d "$CLONE_DIR/.git" ]]; then
  git -C "$CLONE_DIR" pull --quiet
else
  echo "▶ Cloning repo $REPO_URL …"
  if ! git clone --quiet "$REPO_URL" "$CLONE_DIR"; then
    cat <<EOF
❌  Clone failed.  Add this PUBLIC key as a write-enabled deploy key
    in the repo, then rerun this script.

$PUBKEY
EOF
    exit 1
  fi
fi

cd "$CLONE_DIR"

# configure local author identity (once per clone)
git config user.name  "${HOSTNAME}"      || true
git config user.email "${HOSTNAME}@farmslug.local" || true

# -------- Update host_keys.txt & push -------------------------------
if ! grep -q "^${HOSTNAME}[[:space:]]" "$KEY_FILE" 2>/dev/null; then
  echo "▶ Appending this host to $KEY_FILE and pushing…"
  echo "${HOSTNAME}  ${PUBKEY}" >> "$KEY_FILE"
  git add "$KEY_FILE"
  git commit -m "add key for $HOSTNAME" --quiet
  git pull --rebase --quiet || { echo "❌ git pull failed; fix manually."; exit 1; }
  if ! git push 2>/dev/null; then
    echo "❌ git push failed.  Make sure this key is a WRITE deploy key in GitHub."
    exit 1
  fi
fi

# -------- Tailscale --------------------------------------------------
if ! tailscale status --peers=false >/dev/null 2>&1; then
  echo "▶ This Pi is not in the tailnet yet."
  read -rp "Enter your reusable Tailscale auth-key: " TS_AUTH_KEY
  sudo tailscale up --authkey "$TS_AUTH_KEY" \
        --hostname "$HOSTNAME" --ssh --accept-routes
else
  echo "▶ Tailscale already connected."
fi

echo "▶ Installing generate_inventory.sh…"
sudo install -m 0755 "$CLONE_DIR/generate_inventory.sh" /usr/local/bin/

echo "✓ Bootstrap complete on $HOSTNAME"
echo "   Run: generate_inventory.sh && ansible-playbook …"

