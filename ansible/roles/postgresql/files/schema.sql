-- Idempotent schema for racetelem database
-- TimescaleDB extension should already be enabled

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

-- Convert to hypertables (no-op if already hypertables)
SELECT create_hypertable('telemetry', 'time', if_not_exists => TRUE);
SELECT create_hypertable('laptimes', 'time', if_not_exists => TRUE);

-- Indexes (idempotent)
CREATE INDEX IF NOT EXISTS telemetry_time_idx ON telemetry (time DESC);
CREATE INDEX IF NOT EXISTS laptimes_time_idx ON laptimes (time DESC);

-- Ownership
ALTER TABLE telemetry OWNER TO racetelem;
ALTER TABLE laptimes OWNER TO racetelem;
