#!/usr/bin/env bash
set -euo pipefail
OUT=$HOME/hosts.yml
echo "all:" >"$OUT"
echo "  hosts:" >>"$OUT"

tailscale status --json \
 | jq -r '
     [ .Self, (.Peer[]?) ] |
     .[] |
     select(.Tags[]? == "tag:farmslug") |
     "\(.HostName)|\(.DNSName)"
   ' \
 | while IFS="|" read -r host fqdn; do
     echo "    $host:"          >>"$OUT"
     echo "      ansible_host: $fqdn"  >>"$OUT"
     echo "      ansible_user: pi"     >>"$OUT"
   done
echo "Inventory -> $OUT"

