#!/usr/bin/env bash
#
# ansible_bootstrap.sh
# --------------------
# One‑time setup for every “farmslug” Raspberry Pi.
#
# • installs Avahi (mDNS), Git, Ansible
# • ensures avahi‑daemon auto‑starts every boot
# • generates ~/.ssh/id_ed25519 if missing
# • clones *public* repo that holds:
#       – scenario scripts / playbooks
#       – host_keys.txt            (hostname  pubkey)
#       – generate_inventory.sh
# • appends this Pi’s pubkey to host_keys.txt (if new) and pushes
#   ─ requires that this Pi’s **public** key has first been added
#     to the repo as a *write‑enabled* deploy key
# • installs generate_inventory.sh into /usr/local/bin so it can be
#   called from anywhere before running playbooks

set -euo pipefail

REPO_URL="git@github.com:KeatonShawhan/KeysightTestAutomation.git"   # <-- change org/repo
CLONE_DIR="$HOME/KeysightTestAutomation"              # where scripts live after clone
KEY_FILE="host_keys.txt"                     # inside the repo

echo "▶ Installing Avahi, Git, Ansible…"
sudo apt-get update -qq
sudo apt-get install -y avahi-daemon avahi-utils git ansible >/dev/null

echo "▶ Enabling Avahi mDNS service…"
/usr/bin/sudo systemctl enable --now avahi-daemon

echo "▶ Generating SSH key if absent…"
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
fi
PUBKEY=$(<"$HOME/.ssh/id_ed25519.pub")
HOSTNAME=$(hostname)

echo "▶ Cloning (or pulling) $REPO_URL …"
if [[ -d "$CLONE_DIR/.git" ]]; then
  git -C "$CLONE_DIR" pull --quiet
else
  # Use the Pi's own key for auth; disable host‑key checking for first clone
  GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no' \
    git clone --quiet "$REPO_URL" "$CLONE_DIR" || {
      cat <<EOF
❌ Clone failed.  This Pi's SSH key probably isn't a write‑deploy key yet.

Add the following PUBLIC key to the GitHub repo as a **Deploy key
with write access**, then re‑run ansible_bootstrap.sh:

  Host : $HOSTNAME
  Key  : $PUBKEY
EOF
      exit 1
    }
fi

cd "$CLONE_DIR"

echo "▶ Updating host_keys.txt if necessary…"
grep -q "^${HOSTNAME}[[:space:]]" "$KEY_FILE" 2>/dev/null || {
  echo "${HOSTNAME}  ${PUBKEY}" >> "$KEY_FILE"
  git add "$KEY_FILE"
  git commit -m "add key for $HOSTNAME" --quiet
  if ! git push --quiet; then
    cat <<EOF
❌ Push failed.  Most likely this Pi's public key has NOT yet been
added as a write‑enabled deploy key for the repo.

Please add the key you see below to the repo's *Deploy keys*
(✔ “Allow write access”) and run the bootstrap again.

$PUBKEY
EOF
    exit 1
  fi
}

echo "▶ Installing generate_inventory.sh to /usr/local/bin …"
/usr/bin/sudo install -m 0755 "$CLONE_DIR/generate_inventory.sh" /usr/local/bin/

echo "✓ Bootstrap completed on $HOSTNAME"
echo "  Repo cloned to: $CLONE_DIR"
echo "  Next steps:"
echo "    1) cd $CLONE_DIR  &&  git pull   # when you need fresh scripts"
echo "    2) generate_inventory.sh          # create ~/hosts.yml"
echo "    3) ansible-playbook -i ~/hosts.yml push_my_pubkey.yml --ask-pass   # first time"
echo "    4) ansible-playbook -i ~/hosts.yml <your_playbook>.yml            # thereafter"

