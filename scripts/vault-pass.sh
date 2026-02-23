#!/usr/bin/env bash
set -euo pipefail

# Retrieves the Ansible vault password from Bitwarden CLI.
# Requires: bw CLI installed and logged in (bw login / bw unlock).
#
# Set BW_ITEM to the Bitwarden item name containing the vault password.
# The password field of that item is used.

BW_ITEM="${BW_ITEM:-ansible-vault/racing.gus.is}"

if ! command -v bw &>/dev/null; then
    echo "Error: bw (Bitwarden CLI) not found" >&2
    exit 1
fi

if [ -z "${BW_SESSION:-}" ]; then
    echo "Error: BW_SESSION not set. Run: export BW_SESSION=\$(bw unlock --raw)" >&2
    exit 1
fi

PASSWORD=$(bw list items --search "$BW_ITEM" 2>/dev/null \
    | jq -r '[.[] | select(.name == "'"$BW_ITEM"'")] | first | .login.password')

if [ -z "$PASSWORD" ] || [ "$PASSWORD" = "null" ]; then
    echo "Error: Could not find Bitwarden item '$BW_ITEM'" >&2
    exit 1
fi

echo "$PASSWORD"
