#!/usr/bin/env bash
# generate_inventory.sh  – build ~/hosts.yml from Tailscale status
set -euo pipefail

OUT="$HOME/hosts.yml"
FILTER="farmslug"

echo "all:" >"$OUT"
echo "  hosts:" >>"$OUT"

tailscale status --json |
 jq -r --arg f "$FILTER" '
     [ .Self, (.Peer[]?) ] |
     .[] |
     select(.HostName | test($f;"i")) |
     "\(.HostName)|\(.DNSName)"
   ' |
 while IFS="|" read -r host fqdn; do
   echo "    $host:"            >>"$OUT"
   echo "      ansible_host: $fqdn" >>"$OUT"
 done

echo "Inventory written to $OUT ( $(grep -c '^    [^ ]' "$OUT") hosts )"

