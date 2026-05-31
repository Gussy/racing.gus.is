# TimescaleDB Audit

**Date:** 2026-02-23
**Database:** `racetelem` on PostgreSQL 11 + TimescaleDB 1.7.5
**Target:** PostgreSQL 16 + TimescaleDB 2.x (DigitalOcean, 1 vCPU / 2 GB RAM / 5 GB volume)

---

## Current State

### Schema

The `telemetry` table is a TimescaleDB hypertable with 84 chunks:

| Column    | Type                     | Nullable |
|-----------|--------------------------|----------|
| time      | timestamp with time zone | NOT NULL |
| user_id   | integer                  | yes      |
| device_id | integer                  | yes      |
| data      | jsonb                    | yes      |

- **3,214,234 rows** spanning 2019-09-25 to 2025-12-15
- Only `user_id=1`, `device_id=1` exist (single-tenant today)
- JSONB schema evolved from 9 fields (2019) to 40+ fields (2025)
- Single explicit index: `telemetry_time_idx` on `time DESC`

### What's Being Used

- Hypertable with time-based auto-partitioning
- JSONB for flexible telemetry payload
- Grafana dashboards with `data ? 'key_name'` existence checks and `->>`/`->` accessors

### What's NOT Being Used

- Compression policies
- Retention policies
- Continuous aggregates
- Space partitioning
- Row-level security
- GIN indexes on JSONB
- NOT NULL constraints on `user_id`, `device_id`, `data`

### Empty JSONB Finding

**1,819,066 rows (57%) have empty `{}` payloads.** These are heartbeat/keepalive messages where the device was online but not sending sensor data. They consume roughly 900 MB of the 1.6 GB total database. No Grafana query ever matches these rows because every dashboard panel uses `data ? 'some_key'`.

---

## Phase 1: Migration Wins

Do these during the PG 11 to PG 16 migration. Combined effort: ~45 minutes.

### 1.1 Filter Empty JSONB Rows During Import

Do not import the 1.8M empty rows. Pre-filter the CSV export:

```bash
head -1 telemetry.csv > telemetry_filtered.csv
awk -F',' 'NR>1 && $4 != "{}" {print}' telemetry.csv >> telemetry_filtered.csv
```

Or post-import cleanup:

```sql
DELETE FROM telemetry WHERE data = '{}' OR data IS NULL;
```

**Impact:** Database drops from ~1.6 GB to ~700-800 MB. Chunk count drops from 84 to ~40.

**Trade-off:** Loses ability to analyze connectivity/heartbeat patterns.

### 1.2 Add NOT NULL Constraints

```sql
CREATE TABLE IF NOT EXISTS telemetry (
    time      TIMESTAMPTZ NOT NULL,
    user_id   INTEGER NOT NULL,
    device_id INTEGER NOT NULL,
    data      JSONB NOT NULL
);
```

Optionally add a CHECK to reject empty payloads at the database level:

```sql
ALTER TABLE telemetry ADD CONSTRAINT data_not_empty CHECK (data <> '{}'::jsonb);
```

**Trade-off:** The Go `racetelem` API must either skip heartbeat-only POSTs or tag them (e.g. `{"heartbeat": true}`). If the API can't change immediately, defer the CHECK but still add NOT NULL.

### 1.3 Add a GIN Index on JSONB

```sql
CREATE INDEX IF NOT EXISTS telemetry_data_gin_idx
    ON telemetry USING GIN (data);
```

Use `jsonb_ops` (the default), not `jsonb_path_ops`, because the `?` existence operator that all Grafana queries rely on requires it.

**Trade-off:** GIN indexes have higher write overhead and consume ~10-20% of JSONB data size. Negligible at 1-second ingestion from a single device.

### 1.4 Remove the Redundant time DESC Index

```sql
-- DROP this from schema.sql:
-- CREATE INDEX IF NOT EXISTS telemetry_time_idx ON telemetry (time DESC);
```

TimescaleDB automatically creates a B-tree index on `time` for every chunk when `create_hypertable` is called. The explicit index creates a redundant second index across all chunks.

Verify with:

```sql
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'telemetry'
ORDER BY indexname;
```

### 1.5 Set Explicit Chunk Interval

```sql
SELECT create_hypertable('telemetry', 'time',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE
);
```

After filtering, each 7-day chunk holds ~3K-7K rows (~8-10 MB), well under the 500 MB target (25% of 2 GB RAM).

### 1.6 Enable Compression on Historical Data

```sql
ALTER TABLE telemetry SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'device_id',
    timescaledb.compress_orderby = 'time DESC'
);

SELECT add_compression_policy('telemetry', INTERVAL '30 days');
```

After import, manually compress existing chunks:

```sql
SELECT compress_chunk(c, if_not_compressed => true)
FROM show_chunks('telemetry', older_than => INTERVAL '30 days') c;
```

`compress_segmentby = 'device_id'` is chosen with future multi-tenant use in mind.

**Trade-off:** Compressed chunks become read-only. Fine for append-only telemetry. UPDATEs/DELETEs require decompression first (automatic in TimescaleDB 2.11+, but slow).

**Impact:** Historical storage reduced from ~600 MB to ~30-60 MB.

### Updated schema.sql (Post Phase 1)

```sql
CREATE TABLE IF NOT EXISTS telemetry (
    time      TIMESTAMPTZ NOT NULL,
    user_id   INTEGER NOT NULL,
    device_id INTEGER NOT NULL,
    data      JSONB NOT NULL
);

SELECT create_hypertable('telemetry', 'time',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS telemetry_data_gin_idx
    ON telemetry USING GIN (data);

ALTER TABLE telemetry SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'device_id',
    timescaledb.compress_orderby = 'time DESC'
);
SELECT add_compression_policy('telemetry', INTERVAL '30 days');

ALTER TABLE telemetry OWNER TO racetelem;
```

---

## Phase 2: Medium-Term Improvements

After the migration stabilises. These can be done independently.

### 2.1 Sessions Table

No session/event concept currently exists. Adding one enables event-based analysis and Grafana filtering.

```sql
CREATE TABLE IF NOT EXISTS sessions (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    track       TEXT,
    event_type  TEXT CHECK (event_type IN ('race', 'qualifying', 'practice', 'test')),
    start_time  TIMESTAMPTZ NOT NULL,
    end_time    TIMESTAMPTZ,
    user_id     INTEGER,
    notes       TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX sessions_time_idx ON sessions (start_time DESC);

ALTER TABLE telemetry ADD COLUMN session_id INTEGER REFERENCES sessions(id);
CREATE INDEX telemetry_session_idx ON telemetry (session_id, time DESC);
```

**Trade-off:** Historical data will have `session_id = NULL`. Backfilling requires knowing time ranges per event. Go API needs modification.

### 2.2 Continuous Aggregates

Pre-compute rollups so Grafana queries over long time ranges avoid scanning raw rows.

**1-minute rollup:**

```sql
CREATE MATERIALIZED VIEW telemetry_1min
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 minute', time) AS bucket,
    device_id,
    AVG((data->>'engine_rpm')::numeric)      AS avg_rpm,
    MAX((data->>'engine_rpm')::numeric)       AS max_rpm,
    AVG((data->>'water_temp_can')::numeric)   AS avg_water_temp,
    MAX((data->>'water_temp_can')::numeric)   AS max_water_temp,
    AVG((data->>'oil_temperature')::numeric)  AS avg_oil_temp,
    MAX((data->>'oil_temperature')::numeric)  AS max_oil_temp,
    AVG((data->>'fuel_level')::numeric)       AS avg_fuel,
    MIN((data->>'fuel_level')::numeric)       AS min_fuel,
    AVG((data->>'oil_pressure')::numeric)     AS avg_oil_pressure,
    MIN((data->>'oil_pressure')::numeric)     AS min_oil_pressure,
    AVG((data->>'water_pressure')::numeric)   AS avg_water_pressure,
    AVG((data->>'fuel_pressure')::numeric)    AS avg_fuel_pressure,
    COUNT(*)                                  AS sample_count
FROM telemetry
WHERE data <> '{}'::jsonb
GROUP BY bucket, device_id
WITH NO DATA;

SELECT add_continuous_aggregate_policy('telemetry_1min',
    start_offset    => INTERVAL '3 days',
    end_offset      => INTERVAL '1 minute',
    schedule_interval => INTERVAL '1 minute'
);
```

**1-hour rollup:**

```sql
CREATE MATERIALIZED VIEW telemetry_1hr
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', time) AS bucket,
    device_id,
    AVG((data->>'engine_rpm')::numeric)      AS avg_rpm,
    MAX((data->>'engine_rpm')::numeric)       AS max_rpm,
    AVG((data->>'water_temp_can')::numeric)   AS avg_water_temp,
    MAX((data->>'water_temp_can')::numeric)   AS max_water_temp,
    AVG((data->>'oil_temperature')::numeric)  AS avg_oil_temp,
    MAX((data->>'oil_temperature')::numeric)  AS max_oil_temp,
    AVG((data->>'fuel_level')::numeric)       AS avg_fuel,
    MIN((data->>'fuel_level')::numeric)       AS min_fuel,
    COUNT(*)                                  AS sample_count
FROM telemetry
WHERE data <> '{}'::jsonb
GROUP BY bucket, device_id
WITH NO DATA;

SELECT add_continuous_aggregate_policy('telemetry_1hr',
    start_offset    => INTERVAL '30 days',
    end_offset      => INTERVAL '1 hour',
    schedule_interval => INTERVAL '1 hour'
);
```

**Backfill historical data:**

```sql
CALL refresh_continuous_aggregate('telemetry_1min', '2019-01-01', NOW());
CALL refresh_continuous_aggregate('telemetry_1hr', '2019-01-01', NOW());
```

**Trade-off:** Adding new sensor JSONB fields requires recreating or modifying the aggregate. The `->>` cast to `::numeric` returns NULL for missing keys, which `AVG`/`MIN`/`MAX` correctly ignore.

### 2.3 Retention Policy

```sql
SELECT add_retention_policy('telemetry', INTERVAL '2 years');
```

Continuous aggregates are NOT affected by retention policies, so historical rollup data survives.

**Trade-off:** Raw data is irrecoverably deleted. Consider archiving old chunks to DigitalOcean Spaces first. Start conservative at 2 years.

### 2.4 PostgreSQL Tuning (2 GB RAM)

```ini
# Memory (PG gets ~1 GB of 2 GB total)
shared_buffers = 512MB
effective_cache_size = 1GB
work_mem = 16MB
maintenance_work_mem = 128MB

# TimescaleDB
timescaledb.max_background_workers = 4

# WAL
wal_buffers = 16MB
min_wal_size = 256MB
max_wal_size = 1GB

# Planner (SSD storage on DO volumes)
random_page_cost = 1.1
effective_io_concurrency = 200

# Connections (low concurrency: racetelem + Grafana only)
max_connections = 50

# Logging
log_min_duration_statement = 1000  # log queries > 1s
```

### 2.5 Extract Frequently-Queried JSONB Fields (Optional)

Promote hot fields to typed columns for better indexing and lower CPU:

```sql
ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS latitude     DOUBLE PRECISION;
ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS longitude    DOUBLE PRECISION;
ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS engine_rpm   INTEGER;
ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS speed        DOUBLE PRECISION;
ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS water_temp   DOUBLE PRECISION;
ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS oil_temp     DOUBLE PRECISION;
ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS fuel_level   DOUBLE PRECISION;
ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS oil_pressure DOUBLE PRECISION;
```

**Trade-off:** Requires Go API changes and dual storage until Grafana dashboards are migrated. Only implement when the Go API is actively developed again.

---

## Phase 3: Multi-Tenant Readiness

### 3.1 Teams and Devices Tables

```sql
CREATE TABLE IF NOT EXISTS teams (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    slug        TEXT NOT NULL UNIQUE,
    api_key     TEXT NOT NULL UNIQUE,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    active      BOOLEAN DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS devices (
    id          SERIAL PRIMARY KEY,
    team_id     INTEGER NOT NULL REFERENCES teams(id),
    name        TEXT NOT NULL,
    hw_type     TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    active      BOOLEAN DEFAULT TRUE,
    UNIQUE(team_id, name)
);
```

Add `team_id` to telemetry and backfill existing data:

```sql
ALTER TABLE telemetry ADD COLUMN team_id INTEGER REFERENCES teams(id);

-- Backfill
INSERT INTO teams (id, name, slug, api_key)
    VALUES (1, 'A-Team', 'ateam', 'existing-api-key');
INSERT INTO devices (id, team_id, name, hw_type)
    VALUES (1, 1, 'ESP32-001', 'esp32');
UPDATE telemetry SET team_id = 1 WHERE team_id IS NULL;

ALTER TABLE telemetry ALTER COLUMN team_id SET NOT NULL;
```

### 3.2 Row-Level Security (RLS)

```sql
-- Per-team database roles
CREATE ROLE team_ateam LOGIN PASSWORD 'generated-password';
GRANT CONNECT ON DATABASE racetelem TO team_ateam;
GRANT USAGE ON SCHEMA public TO team_ateam;
GRANT SELECT ON telemetry, sessions, teams, devices TO team_ateam;

-- Enable RLS
ALTER TABLE telemetry ENABLE ROW LEVEL SECURITY;

-- Team isolation
CREATE POLICY team_isolation_telemetry ON telemetry
    FOR SELECT
    USING (team_id = (SELECT id FROM teams WHERE slug = current_user::text));

-- Admin (racetelem API) keeps full access
ALTER TABLE telemetry FORCE ROW LEVEL SECURITY;
CREATE POLICY admin_all_telemetry ON telemetry
    FOR ALL TO racetelem
    USING (true) WITH CHECK (true);
```

### 3.3 Space Partitioning by team_id

```sql
SELECT add_dimension('telemetry', 'team_id', number_partitions => 4);
```

Start only when 2+ active teams exist. Space partitioning can only be added to empty hypertables or via migration (create new hypertable, copy data, swap).

### 3.4 Update Compression for Multi-Tenant

```sql
ALTER TABLE telemetry SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'team_id, device_id',
    timescaledb.compress_orderby = 'time DESC'
);
```

### 3.5 API Authentication

- Devices authenticate via `X-API-Key: <team_api_key>` header
- API resolves `team_id` from `teams` table (cached in memory)
- `team_id` and `device_id` injected into every INSERT
- Rate limiting per team
- Existing single-team device grandfathered with default key

### 3.6 Grafana Multi-Tenant

**Recommended for <10 teams: Grafana Organizations.** Create a Grafana org per team, each with its own datasource connecting with the team's DB role (RLS enforced). Dashboards provisioned identically per org. Teams cannot see each other's data.

**Alternative:** Single org with a `$team` variable and `WHERE team_id = $team`. Less secure but simpler.

---

## Priority Table

| # | Item | Phase | Effort | Impact |
|---|------|-------|--------|--------|
| 1 | Filter empty JSONB rows during import | 1.1 | 10 min | High -- saves 57% storage |
| 2 | Enable compression + policy | 1.6 | 15 min | High -- 10-20x on historical data |
| 3 | Add GIN index on JSONB | 1.3 | 5 min | High -- speeds all Grafana queries |
| 4 | Remove redundant time index | 1.4 | 5 min | Medium -- saves space + write overhead |
| 5 | Set explicit chunk interval | 1.5 | 5 min | Low -- documentation/consistency |
| 6 | Add NOT NULL constraints | 1.2 | 5 min | Medium -- schema may need Go API change |
| 7 | PostgreSQL tuning | 2.4 | 30 min | Medium |
| 8 | Sessions table | 2.1 | 1 hr | Medium -- enables event-based analysis |
| 9 | Continuous aggregates | 2.2 | 2 hrs | Medium -- speeds historical dashboards |
| 10 | Retention policy | 2.3 | 10 min | Low urgency now, critical at scale |
| 11 | Teams + devices tables | 3.1 | 2 hrs | Required for multi-tenant |
| 12 | Row-level security | 3.2 | 2 hrs | Required for multi-tenant |
| 13 | Space partitioning | 3.3 | 1 hr | Multi-tenant optimisation |
| 14 | Typed columns | 2.5 | 4 hrs | Performance optimisation (deferred) |

---

## Monitoring Queries

Check hypertable sizes:

```sql
SELECT hypertable_name,
       pg_size_pretty(hypertable_size(
           format('%I.%I', hypertable_schema, hypertable_name)
       )) AS total_size
FROM timescaledb_information.hypertables;
```

Enable query statistics:

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

Plan to increase from 5 GB to 10 GB volume when nearing 3 GB usage. Multi-tenant with 5-10 teams at 1 Hz each generates ~5-10M rows/year.
