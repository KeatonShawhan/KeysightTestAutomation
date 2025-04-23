#!/usr/bin/env bash
# generate_inventory.sh  – build ~/hosts.yml from tailscale status
set -euo pipefail

OUT="$HOME/hosts.yml"
FILTER="farmslug"
ANSIBLE_USER="pi"

echo "all:" >"$OUT"
echo "  hosts:" >>"$OUT"

tailscale status --json \
 | jq -r --arg f "$FILTER" '
     [ .Self, (.Peer[]?) ]             # array of self + peers
     | .[]                             # iterate
     | select(.HostName | test($f;"i"))   # keep names containing "farmslug"
     | "\(.HostName):\n  ansible_host: \(.TailscaleIPs[0])\n  ansible_user: '$ANSIBLE_USER'"' \
 | while read -r line; do
     # lines come grouped in blocks of 3; indent to YAML
     echo "    $line" >>"$OUT"
   done

echo "Inventory written to $OUT"

