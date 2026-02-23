#!/usr/bin/env bash
set -euo pipefail

# Sets up the Ansible vault for racing.gus.is:
#   1. Creates a Bitwarden item with a generated vault password
#   2. Generates strong passwords for PG and Grafana
#   3. Creates and encrypts ansible/inventory/group_vars/all/vault.yml
#
# Prerequisites:
#   - bw CLI logged in and unlocked (export BW_SESSION=$(bw unlock --raw))
#   - Tailscale auth key ready (from https://login.tailscale.com/admin/settings/keys)

BW_ITEM="${BW_ITEM:-ansible-vault/racing.gus.is}"
VAULT_FILE="ansible/inventory/group_vars/all/vault.yml"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

# --- Preflight checks ---

if ! command -v bw &>/dev/null; then
    echo "Error: bw (Bitwarden CLI) not found. Run: source bin/activate-hermit" >&2
    exit 1
fi

if [ -z "${BW_SESSION:-}" ]; then
    echo "Error: BW_SESSION not set. Run: export BW_SESSION=\$(bw unlock --raw)" >&2
    exit 1
fi

if [ -f "$VAULT_FILE" ]; then
    echo "Error: $VAULT_FILE already exists. Delete it first if you want to recreate." >&2
    exit 1
fi

# --- Prompt for Tailscale auth key ---

read -rsp "Tailscale auth key (from admin console): " TAILSCALE_KEY
echo
if [ -z "$TAILSCALE_KEY" ]; then
    echo "Error: Tailscale auth key is required" >&2
    exit 1
fi

# --- Generate passwords via Bitwarden ---

VAULT_PASSWORD=$(bw generate --length 40)
PG_PASSWORD=$(bw generate --length 40)
GRAFANA_PASSWORD=$(bw generate --length 32)

echo "Generated vault password and service credentials."

# --- Helper: create or update a Bitwarden login item ---

bw_upsert_item() {
    local name="$1" username="$2" password="$3" notes="$4"

    # Check if item already exists (exact name match)
    local existing
    existing=$(bw list items --search "$name" 2>/dev/null \
        | jq -r '[.[] | select(.name == "'"$name"'")] | first // empty')

    if [ -n "$existing" ]; then
        local item_id
        item_id=$(echo "$existing" | jq -r '.id')
        # Update the existing item
        echo "$existing" | jq \
            --arg password "$password" \
            --arg username "$username" \
            --arg notes "$notes" \
            '.login.password = $password | .login.username = $username | .notes = $notes' \
            | bw encode | bw edit item "$item_id" | jq -r '.id'
    else
        # Create a new item
        local json
        json=$(bw get template item | jq \
            --arg name "$name" \
            --arg username "$username" \
            --arg password "$password" \
            --arg notes "$notes" \
            '.name = $name | .login.password = $password | .login.username = $username | .notes = $notes')
        echo "$json" | bw encode | bw create item | jq -r '.id'
    fi
}

# --- Store all credentials in Bitwarden ---

echo "Storing credentials in Bitwarden..."

VAULT_ID=$(bw_upsert_item \
    "$BW_ITEM" \
    "ansible-vault" \
    "$VAULT_PASSWORD" \
    "Ansible vault password for racing.gus.is")
echo "  $BW_ITEM ($VAULT_ID)"

PG_ID=$(bw_upsert_item \
    "racing.gus.is/postgresql" \
    "racetelem" \
    "$PG_PASSWORD" \
    "PostgreSQL racetelem user for racing.gus.is")
echo "  racing.gus.is/postgresql ($PG_ID)"

GRAFANA_ID=$(bw_upsert_item \
    "racing.gus.is/grafana" \
    "admin" \
    "$GRAFANA_PASSWORD" \
    "Grafana admin user for racing.gus.is")
echo "  racing.gus.is/grafana ($GRAFANA_ID)"

TS_ID=$(bw_upsert_item \
    "racing.gus.is/tailscale" \
    "auth-key" \
    "$TAILSCALE_KEY" \
    "Tailscale auth key for racing.gus.is")
echo "  racing.gus.is/tailscale ($TS_ID)"

bw sync

# --- Create and encrypt the vault file ---

echo "Creating $VAULT_FILE..."

cat > "$VAULT_FILE" <<EOF
---
vault_pg_password: "$PG_PASSWORD"
vault_grafana_admin_password: "$GRAFANA_PASSWORD"
vault_tailscale_auth_key: "$TAILSCALE_KEY"
EOF

echo "Encrypting $VAULT_FILE..."
ansible-vault encrypt "$VAULT_FILE" --vault-password-file <(echo "$VAULT_PASSWORD")

echo ""
echo "Done! Bitwarden items created:"
echo "  $BW_ITEM           — vault password"
echo "  racing.gus.is/postgresql  — PG user: racetelem"
echo "  racing.gus.is/grafana     — Grafana user: admin"
echo "  racing.gus.is/tailscale   — Tailscale auth key"
echo ""
echo "Vault file: $VAULT_FILE (encrypted)"
echo ""
echo "To view vault contents:  ansible-vault view $VAULT_FILE"
echo "To edit vault contents:  ansible-vault edit $VAULT_FILE"
