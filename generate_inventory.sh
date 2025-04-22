#!/usr/bin/env bash
#
# generate_inventory.sh
# ---------------------
# Creates an Ansible inventory file (YAML) listing every host on the LAN
# whose mDNS name contains the substring “farmslug”.
#
#  ▸ Out‑file:  ~/hosts.yml
#  ▸ Each host is addressed via <hostname>.local
#  ▸ Assumes the login user is “pi”; adjust ANSIBLE_USER below if needed.
#
# Usage:
#   generate_inventory.sh        # writes ~/hosts.yml
#   ansible-playbook -i ~/hosts.yml <playbook>.yml  ...
#

OUT_FILE="$HOME/hosts.yml"
ANSIBLE_USER="pi"            # change if you use a different login
FILTER="farmslug"            # substring to match in hostnames

echo "all:" > "$OUT_FILE"
echo "  hosts:" >> "$OUT_FILE"

# -r : resolve;  -t : terminate on end;  -p show txt;  _workstation._tcp is default Avahi service
avahi-browse -rt _workstation._tcp 2>/dev/null \
  | awk -F';' -v f="$FILTER" '
      /IPv4/ && tolower($8) ~ f {print $8}
    ' \
  | sort -u \
  | while read -r host; do
      printf "    %s:\n      ansible_host: %s.local\n      ansible_user: %s\n" \
        "$host" "$host" "$ANSIBLE_USER" >> "$OUT_FILE"
    done

printf "Inventory written to %s (found %d hosts)\n" "$OUT_FILE" \
        "$(grep -c '^    ' "$OUT_FILE")"

