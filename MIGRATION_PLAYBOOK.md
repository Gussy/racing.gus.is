# Migration Playbook: Old Server → New Server

Step-by-step runbook for migrating racing.gus.is from the legacy server (138.68.208.150) to the new IaC-managed server.

**Strategy:** Option C from [TIMESCALEDB_MIGRATION.md](TIMESCALEDB_MIGRATION.md) — fresh schema + CSV data load. No direct TimescaleDB upgrade needed.

**Old server:** 138.68.208.150 — PG 11 + TimescaleDB 1.7.5 + Grafana 9.1.2
**New server:** IaC-managed — PG 16 + TimescaleDB 2.x + Grafana (latest)

---

## Part 1: Export from Old Server

### 1.1 Export TimescaleDB Data as CSV

SSH into the old server:

```bash
ssh gus@138.68.208.150
```

Export both tables:

```bash
# telemetry — 3.2M rows, will take a minute or two
sudo su - postgres -c "psql -d racetelem -c \"\\copy (SELECT * FROM telemetry ORDER BY time) TO '/tmp/telemetry.csv' WITH CSV HEADER\""

# laptimes — 288 rows, instant
sudo su - postgres -c "psql -d racetelem -c \"\\copy (SELECT * FROM laptimes ORDER BY time) TO '/tmp/laptimes.csv' WITH CSV HEADER\""
```

Verify the exports:

```bash
wc -l /tmp/telemetry.csv /tmp/laptimes.csv
# Expected: ~3,214,235 telemetry.csv (3,214,234 rows + header)
#           ~289 laptimes.csv (288 rows + header)
```

Make them readable for scp:

```bash
sudo chmod 644 /tmp/telemetry.csv /tmp/laptimes.csv
```

### 1.2 Export Grafana Dashboards via API

Still on the old server, export all 4 dashboards as JSON. Get the Grafana admin password from Bitwarden first; Grafana runs on localhost:3000.

```bash
mkdir -p /tmp/grafana-export
GRAFANA_PASS="<admin password from Bitwarden>"

# List all dashboards to get their UIDs
curl -s -u "admin:${GRAFANA_PASS}" http://localhost:3000/api/search?type=dash-db | python3 -m json.tool
```

Export each dashboard by UID (update the UIDs from the search results above):

```bash
# For each dashboard UID returned by the search, run:
# curl -s -u "admin:${GRAFANA_PASS}" http://localhost:3000/api/dashboards/uid/<UID> | python3 -m json.tool > /tmp/grafana-export/<name>.json

# Example (replace UIDs with actual values from the search):
for uid in $(curl -s -u "admin:${GRAFANA_PASS}" http://localhost:3000/api/search?type=dash-db | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    print(d['uid'])
"); do
  title=$(curl -s -u "admin:${GRAFANA_PASS}" "http://localhost:3000/api/dashboards/uid/$uid" | python3 -c "
import sys, json
print(json.load(sys.stdin)['dashboard']['title'].replace(' ', '_').lower())
")
  curl -s -u "admin:${GRAFANA_PASS}" "http://localhost:3000/api/dashboards/uid/$uid" > "/tmp/grafana-export/${title}.json"
  echo "Exported: $title ($uid)"
done
```

Verify 4 dashboards were exported:

```bash
ls -la /tmp/grafana-export/
# Expected: esp32_uptime.json, general_alerting.json, race.json, race_new.json (or similar)
```

### 1.3 Backup Grafana SQLite DB

As a safety net, also grab the raw SQLite database:

```bash
sudo cp /var/lib/grafana/grafana.db /tmp/grafana.db
sudo chmod 644 /tmp/grafana.db
```

### 1.4 Copy Everything to Local Machine

From your local machine:

```bash
mkdir -p ~/migration-export

# CSV data
scp gus@138.68.208.150:/tmp/telemetry.csv ~/migration-export/
scp gus@138.68.208.150:/tmp/laptimes.csv ~/migration-export/

# Grafana dashboards
scp -r gus@138.68.208.150:/tmp/grafana-export ~/migration-export/

# Grafana SQLite backup
scp gus@138.68.208.150:/tmp/grafana.db ~/migration-export/
```

Verify everything arrived:

```bash
ls -lh ~/migration-export/
ls -la ~/migration-export/grafana-export/
wc -l ~/migration-export/telemetry.csv ~/migration-export/laptimes.csv
```

---

## Part 2: Spin Up New Server

### 2.1 Run the Standard Spinup

Follow [DEPLOY.md](DEPLOY.md) steps 1–4 if this is the first time. If the vault and infra are already configured:

```bash
task build    # rebuild racetelem binary
task spinup   # creates droplet, configures everything via Ansible
```

This automatically:
- Creates the DigitalOcean droplet + persistent volume + firewall
- Installs PG 16 + TimescaleDB 2.x
- Creates `racetelem` database + user + schema (both hypertables)
- Installs Grafana + all 7 plugins + provisions the PostgreSQL datasource
- Deploys racetelem binary as a systemd service
- Sets up Caddy reverse proxy with automatic HTTPS
- Configures Tailscale, UFW, fail2ban
- Updates DNS A/AAAA records

### 2.2 Verify the New Server Is Running

```bash
ssh racing-gus-is   # via Tailscale
systemctl status postgresql grafana-server racetelem caddy
psql -U racetelem -d racetelem -c '\dt'
# Should show telemetry and laptimes tables (empty)
```

---

## Part 3: Import into New Server

### 3.1 Upload CSV Files

Upload to `/tmp/` (not `/root/` — the `postgres` user can't read files in `/root/`):

```bash
scp ~/migration-export/telemetry.csv racing-gus-is:/tmp/
scp ~/migration-export/laptimes.csv racing-gus-is:/tmp/
```

On the new server, make sure `postgres` can read them:

```bash
ssh racing-gus-is
chown postgres:postgres /tmp/telemetry.csv /tmp/laptimes.csv
```

### 3.2 Verify Schema Exists

The Ansible `postgresql_script` module can silently fail. Before loading data, confirm the tables exist:

```bash
sudo su - postgres -c "psql -d racetelem -c '\dt'"
```

If `telemetry` and `laptimes` are **not listed**, apply the schema manually:

```bash
sudo su - postgres -c "psql -d racetelem" <<'EOF'
CREATE TABLE IF NOT EXISTS telemetry (
    time      TIMESTAMPTZ NOT NULL,
    user_id   INTEGER,
    device_id INTEGER,
    data      JSONB
);
CREATE TABLE IF NOT EXISTS laptimes (
    time     TIMESTAMPTZ NOT NULL,
    lap      INTEGER,
    position INTEGER,
    laptime  TIME(3) WITHOUT TIME ZONE,
    gap      TIME(3) WITHOUT TIME ZONE,
    diff     TIME(3) WITHOUT TIME ZONE,
    speed    DOUBLE PRECISION
);
SELECT create_hypertable('telemetry', 'time', if_not_exists => TRUE);
SELECT create_hypertable('laptimes', 'time', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS telemetry_time_idx ON telemetry (time DESC);
CREATE INDEX IF NOT EXISTS laptimes_time_idx ON laptimes (time DESC);
ALTER TABLE telemetry OWNER TO racetelem;
ALTER TABLE laptimes OWNER TO racetelem;
EOF
```

### 3.3 Load Data

**Option A — psql \copy (simple):**

```bash
sudo su - postgres -c "psql -d racetelem -c \"\\copy telemetry FROM '/tmp/telemetry.csv' WITH CSV HEADER\""
sudo su - postgres -c "psql -d racetelem -c \"\\copy laptimes FROM '/tmp/laptimes.csv' WITH CSV HEADER\""
```

**Option B — timescaledb-parallel-copy (faster for telemetry):**

```bash
# Install if not present
go install github.com/timescale/timescaledb-parallel-copy@latest

# Load telemetry with parallel workers
timescaledb-parallel-copy \
    --connection "host=localhost user=racetelem dbname=racetelem sslmode=disable" \
    --table telemetry \
    --file /tmp/telemetry.csv \
    --workers 4 \
    --copy-options "CSV HEADER"

# laptimes is tiny, psql is fine
sudo su - postgres -c "psql -d racetelem -c \"\\copy laptimes FROM '/tmp/laptimes.csv' WITH CSV HEADER\""
```

Note: You may need to set the `racetelem` user's password for the parallel-copy connection string. Get it from Bitwarden (`racing.gus.is/postgresql`) or the Ansible vault.

### 3.4 Upload and Import Grafana Dashboards

Upload the exported dashboard JSON files:

```bash
scp ~/migration-export/grafana-export/*.json racing-gus-is:/tmp/
```

SSH into the new server and import each dashboard. The import script rewrites all datasource references to point at the new server's provisioned datasource (the old dashboards reference the old Grafana's internal datasource ID, which won't exist on the new instance).

Get the Grafana admin password from Bitwarden (`racing.gus.is/grafana`):

```bash
ssh racing-gus-is

GRAFANA_PASS="<admin password from Bitwarden>"

# Get the new datasource UID (provisioned by Ansible)
DS_UID=$(curl -s -u "admin:${GRAFANA_PASS}" http://localhost:3000/api/datasources | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['uid'])")
echo "Datasource UID: $DS_UID"

for file in /tmp/*.json; do
  python3 -c "
import json, sys

with open('$file') as f:
    data = json.load(f)

dashboard = data['dashboard']
dashboard.pop('id', None)      # remove old ID so Grafana creates a new one

# Rewrite all datasource references to the new provisioned datasource
def fix_ds(obj):
    if isinstance(obj, dict):
        if 'datasource' in obj:
            ds = obj['datasource']
            if isinstance(ds, str):
                obj['datasource'] = {'type': 'postgres', 'uid': '$DS_UID'}
            elif isinstance(ds, dict):
                ds['uid'] = '$DS_UID'
                ds.setdefault('type', 'postgres')
        for v in obj.values():
            fix_ds(v)
    elif isinstance(obj, list):
        for item in obj:
            fix_ds(item)

fix_ds(dashboard)

payload = {
    'dashboard': dashboard,
    'overwrite': True,
    'inputs': [],
    'folderId': 0
}
json.dump(payload, sys.stdout)
" | curl -s -X POST \
    -H 'Content-Type: application/json' \
    -u "admin:${GRAFANA_PASS}" \
    -d @- \
    http://localhost:3000/api/dashboards/db
  echo ""
  echo "Imported: $file"
done
```

Verify all 4 dashboards appear:

```bash
curl -s -u "admin:${GRAFANA_PASS}" http://localhost:3000/api/search?type=dash-db | python3 -m json.tool
```

### 3.5 Recreate Grafana Users

The admin user is already set up by Ansible. Create the `ateam` user:

```bash
GRAFANA_PASS="<admin password from Bitwarden>"

curl -s -X POST \
  -H 'Content-Type: application/json' \
  -u "admin:${GRAFANA_PASS}" \
  -d '{
    "name": "ateam",
    "login": "ateam",
    "password": "<choose a password>",
    "OrgId": 1,
    "role": "Viewer"
  }' \
  http://localhost:3000/api/admin/users
```

---

## Part 4: Verification

### 4.1 Validate Row Counts

On the new server:

```bash
sudo su - postgres -c "psql -d racetelem -c 'SELECT count(*) FROM telemetry;'"
# Expected: 3,214,234

sudo su - postgres -c "psql -d racetelem -c 'SELECT count(*) FROM laptimes;'"
# Expected: 288
```

Cross-check against the old server if needed:

```bash
ssh gus@138.68.208.150 "sudo su - postgres -c \"psql -d racetelem -c 'SELECT count(*) FROM telemetry;'\""
```

### 4.2 Verify Date Range

```bash
sudo su - postgres -c "psql -d racetelem -c 'SELECT min(time), max(time) FROM telemetry;'"
# Expected: 2019-09-25 to 2025-12-15
```

### 4.3 Verify Grafana Dashboards

Open in browser:

```
https://racing.gus.is/grafana/
```

Check each dashboard:
- [ ] ESP32 Uptime — loads, shows data
- [ ] General Alerting — loads, shows data
- [ ] Race — loads, shows data, trackmap panel works
- [ ] Race New — loads, shows data

Confirm the PostgreSQL datasource connects (Settings > Data Sources > PostgreSQL > Test).

### 4.4 Smoke Test racetelem API

```bash
# From anywhere
curl -s https://racing.gus.is/api/telemetry | head -c 200

# From the server
curl -s http://localhost:8080/api/telemetry | head -c 200
```

### 4.5 DNS Cutover Checklist

DNS is updated automatically by `task spinup`, but verify:

```bash
dig +short racing.gus.is A
dig +short racing.gus.is AAAA
# Should return the new server IP
```

- [ ] DNS A record points to new server
- [ ] HTTPS works (Caddy auto-provisions certificates)
- [ ] Old server can be powered off without impact

---

## Cleanup

After verifying everything works:

```bash
# Remove temporary files from old server
ssh gus@138.68.208.150 "sudo rm /tmp/telemetry.csv /tmp/laptimes.csv /tmp/grafana.db && sudo rm -rf /tmp/grafana-export"

# Remove temporary files from new server
ssh racing-gus-is "rm /tmp/telemetry.csv /tmp/laptimes.csv /tmp/*.json"

# Keep local exports as backup for a while
# rm -rf ~/migration-export  # when you're confident
```

---

## Rollback

If something goes wrong, the old server at 138.68.208.150 is still running. To roll back:

1. Point DNS back to the old IP: update the `digitalocean_record` in OpenTofu or manually in the DO dashboard
2. The old server's certs are still valid (expires 2026-04-19)
3. To destroy the new server: `task teardown` (preserves the data volume)
