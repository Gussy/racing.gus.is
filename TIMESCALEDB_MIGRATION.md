# TimescaleDB Migration: 1.7.5 (PG 11) → 2.x (PG 16+)

## The Problem

The current server runs **TimescaleDB 1.7.5 on PostgreSQL 11**. Both are EOL:
- PostgreSQL 11 has been EOL since November 2023
- TimescaleDB 1.x is long superseded by 2.x

You cannot upgrade both at the same time — they must be handled in a specific order. Additionally, `pg_dump` does not record the TimescaleDB extension version in the backup, so restoring a dump into a database with a *different* TimescaleDB version will break the internal catalog state.

### Current State

| Component   | Current Version | Target          |
|-------------|-----------------|-----------------|
| PostgreSQL  | 11.17           | 16 or 17       |
| TimescaleDB | 1.7.5           | 2.x (latest)   |
| Database    | `racetelem`     | 1.6 GB          |
| Rows        | telemetry: 3.2M, laptimes: 288 | |
| Date range  | 2019-09-25 to 2025-12-15       | |

### Version Compatibility Constraint

There is **no direct upgrade path from TimescaleDB 1.7.5 to 2.0.1**. You must target **2.0.2 or later** (or 2.1.0+), which include the migration scripts for 1.7.5. See [timescale/timescaledb#2976](https://github.com/timescale/timescaledb/issues/2976).

---

## Migration Strategies

### Option A: In-place stepwise upgrade on old server, then dump/restore

**Steps:**
1. Upgrade TimescaleDB 1.7.5 → 2.0.2+ on PG 11:
   ```bash
   # Install the TimescaleDB 2.x package for PG 11
   sudo apt install timescaledb-2-postgresql-11
   ```
   ```sql
   -- In psql connected to racetelem
   ALTER EXTENSION timescaledb UPDATE;
   ```
2. Upgrade PostgreSQL 11 → 14+ using `pg_upgrade`
3. Upgrade TimescaleDB to latest on PG 14+
4. `pg_dump` and restore onto the new server

**Pros:** Follows the officially documented path.
**Cons:** Requires doing surgery on the running production server. Multiple restart cycles. Risk of breakage mid-upgrade.

### Option B: Dump/restore with version matching on new server

**Steps:**
1. Dump the database on the old server:
   ```bash
   pg_dump -Fc -f racetelem.dump racetelem
   ```
2. On the new server, temporarily install **PG 11 + TimescaleDB 1.7.5** (must match exactly)
3. Restore into the matching environment:
   ```bash
   createdb -U postgres racetelem
   psql -U postgres -d racetelem -c "CREATE EXTENSION timescaledb;"
   pg_restore -U postgres -d racetelem racetelem.dump
   ```
4. Upgrade TimescaleDB in-place:
   ```sql
   ALTER EXTENSION timescaledb UPDATE;
   ```
5. `pg_upgrade` from PG 11 → PG 16/17
6. Uninstall PG 11

**Pros:** No changes to the old server. Clean separation.
**Cons:** Need to install old PG 11 + TimescaleDB 1.7.5 packages temporarily on the new server, which may be hard to find for modern Ubuntu.

### Option C: Fresh schema + data load (recommended)

Since the database is only 1.6 GB with a simple schema (2 tables, 2 hypertables), the cleanest approach is to skip the extension upgrade entirely and just move the raw data.

**Steps:**

1. **Export the data from the old server:**
   ```bash
   # Dump telemetry data as CSV
   sudo su - postgres -c "psql -d racetelem -c \"\\copy (SELECT * FROM telemetry ORDER BY time) TO '/tmp/telemetry.csv' WITH CSV HEADER\""

   # Dump laptimes data as CSV
   sudo su - postgres -c "psql -d racetelem -c \"\\copy (SELECT * FROM laptimes ORDER BY time) TO '/tmp/laptimes.csv' WITH CSV HEADER\""
   ```

2. **Copy the files off the server:**
   ```bash
   scp gus@racing.gus.is:/tmp/telemetry.csv .
   scp gus@racing.gus.is:/tmp/laptimes.csv .
   ```

3. **On the new server** (modern PG 16 + TimescaleDB 2.x, set up via Ansible):
   ```sql
   -- Create the user and database
   CREATE USER racetelem WITH PASSWORD '...';
   CREATE DATABASE racetelem OWNER racetelem;

   -- Connect to racetelem
   \c racetelem

   -- Enable TimescaleDB
   CREATE EXTENSION IF NOT EXISTS timescaledb;

   -- Create tables
   CREATE TABLE telemetry (
       time    TIMESTAMPTZ NOT NULL,
       user_id INTEGER,
       device_id INTEGER,
       data    JSONB
   );

   CREATE TABLE laptimes (
       time     TIMESTAMPTZ NOT NULL,
       lap      INTEGER,
       position INTEGER,
       laptime  TIME(3) WITHOUT TIME ZONE,
       gap      TIME(3) WITHOUT TIME ZONE,
       diff     TIME(3) WITHOUT TIME ZONE,
       speed    DOUBLE PRECISION
   );

   -- Convert to hypertables
   SELECT create_hypertable('telemetry', 'time');
   SELECT create_hypertable('laptimes', 'time');

   -- Create indexes
   CREATE INDEX telemetry_time_idx ON telemetry (time DESC);
   CREATE INDEX laptimes_time_idx ON laptimes (time DESC);

   -- Grant ownership
   ALTER TABLE telemetry OWNER TO racetelem;
   ALTER TABLE laptimes OWNER TO racetelem;
   ```

4. **Load the data:**
   ```sql
   \copy telemetry FROM '/path/to/telemetry.csv' WITH CSV HEADER
   \copy laptimes FROM '/path/to/laptimes.csv' WITH CSV HEADER
   ```
   For faster loading, use [timescaledb-parallel-copy](https://github.com/timescale/timescaledb-parallel-copy):
   ```bash
   timescaledb-parallel-copy \
       --connection "host=localhost user=racetelem dbname=racetelem" \
       --table telemetry \
       --file telemetry.csv \
       --workers 4 \
       --copy-options "CSV HEADER"
   ```

**Pros:**
- No version compatibility issues at all
- Clean start with modern PG + TimescaleDB
- Simple, well-understood process (just CSV import)
- 3.2M rows loads in seconds on modern hardware
- Schema is fully documented and reproducible

**Cons:**
- Need to manually recreate the schema (documented above)
- Any Grafana queries referencing TimescaleDB-internal tables would need updating (unlikely given the simple schema)

---

## Recommendation

**Option C (fresh schema + data load)** is the best fit because:
- The schema is simple (2 tables)
- The data volume is small (1.6 GB, 3.2M rows)
- You're already rebuilding the entire server as IaC
- It avoids the fragile version-stepping upgrade dance
- The new server gets a clean, modern stack from day one

---

## Don't Forget: Grafana

The Grafana SQLite database (`/var/lib/grafana/grafana.db`) contains dashboards, datasources, and users. Back this up separately:

```bash
scp gus@racing.gus.is:/var/lib/grafana/grafana.db ./grafana.db.backup
```

The datasource in Grafana points to `localhost:5432` with the `racetelem` credentials — this will work on the new server as-is once PostgreSQL is set up with the same user/password.

---

## References

- [How to upgrade TimescaleDB from 1.6/1.7 to 2.x on PostgreSQL 11](https://www.linkedin.com/pulse/how-upgrade-timescaledb-from-1617-2x-version-11x-arvind-toorpu)
- [TimescaleDB Issue #2976 — no upgrade path from 1.7.5 to 2.0.1](https://github.com/timescale/timescaledb/issues/2976)
- [TimescaleDB Logical Backup Docs](https://docs.tigerdata.com/self-hosted/latest/backup-and-restore/logical-backup/)
- [TimescaleDB Upgrade PostgreSQL Docs](https://docs.timescale.com/self-hosted/latest/upgrades/upgrade-pg/)
- [TimescaleDB Major Version Upgrade](https://docs.tigerdata.com/self-hosted/latest/upgrades/major-upgrade/)
