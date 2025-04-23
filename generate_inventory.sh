#!/usr/bin/env bash
# generate_inventory.sh  – build ~/hosts.yml from Tailscale status
set -euo pipefail

OUT="$HOME/hosts.yml"
FILTER="farmslug"          # substring to match hostnames
MY_HOST="$(hostname)"      # controller's own hostname

echo "all:" >"$OUT"
echo "  hosts:" >>"$OUT"

tailscale status --json \
 | jq -r --arg f "$FILTER" --arg me "$MY_HOST" '
     [ .Self, (.Peer[]?) ]            # array of self + peers
     | .[]                            # iterate
     | select(.HostName | test($f;"i"))
     | "\(.HostName)|\(.DNSName)|\(.HostName==$me)"
   ' \
 | while IFS="|" read -r host fqdn is_me; do
     echo "    $host:" >>"$OUT"
     if [[ "$is_me" == "true" ]]; then
       echo "      ansible_host: 127.0.0.1"  >>"$OUT"
       echo "      ansible_connection: local" >>"$OUT"
     else
       echo "      ansible_host: $fqdn" >>"$OUT"
     fi
   done

echo "Inventory written to $OUT  ( $(grep -c '^    [^ ]' "$OUT") hosts )"

