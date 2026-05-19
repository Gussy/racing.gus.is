# Telemetry Service Integration Guide

The racetelem service accepts JSON telemetry messages, stores them in
PostgreSQL/TimescaleDB, and exposes a coalesced current-state snapshot for
overlays and integrations.

Base URL:

```text
https://racing.gus.is
```

## Current State Snapshot

Fetch the current coalesced telemetry state:

```http
GET /api/telemetry
```

Optional query parameter:

| Parameter | Default | Description |
| --- | ---: | --- |
| `time_window` | `120` | Lookback window in seconds. Must be a positive integer. |

Example:

```bash
curl -s 'https://racing.gus.is/api/telemetry?time_window=86400' | jq
```

Success response:

```json
{
  "status": true,
  "message": "ok",
  "time": "2026-05-19T07:36:31.634761Z",
  "data": {
    "source": "esp32_direct",
    "product_id": "driver_id",
    "message_type": "driver_status",
    "driver_name": "Unknown",
    "tire_pressure_fl": 252.08
  }
}
```

If no telemetry has arrived within the window:

```json
{
  "status": true,
  "message": "ok",
  "time": null,
  "data": {}
}
```

Invalid `time_window` values return `400`:

```json
{
  "status": false,
  "message": "time_window must be a positive integer number of seconds"
}
```

## Websocket Snapshot Stream

Subscribe to full-state snapshots:

```text
wss://racing.gus.is/api/telemetry/ws
```

The websocket accepts the same `time_window` parameter:

```text
wss://racing.gus.is/api/telemetry/ws?time_window=86400
```

Behavior:

- Sends the full coalesced state immediately after connection.
- Sends the full coalesced state again after each successful telemetry POST.
- Does not send periodic heartbeats.
- Allows browser clients from any origin, including local OBS browser sources.

Example with `wscat`:

```bash
npx wscat -c 'wss://racing.gus.is/api/telemetry/ws?time_window=86400'
```

Example browser client:

```html
<script>
  const socket = new WebSocket("wss://racing.gus.is/api/telemetry/ws?time_window=86400");

  socket.addEventListener("message", (event) => {
    const snapshot = JSON.parse(event.data);
    if (!snapshot.status) return;

    console.log(snapshot.time, snapshot.data);
  });
</script>
```

## Writing Telemetry

Send telemetry messages as arbitrary top-level JSON objects:

```http
POST /api/telemetry
Content-Type: application/json
```

Example:

```bash
curl -s https://racing.gus.is/api/telemetry \
  -H 'Content-Type: application/json' \
  -d '{"source":"esp32_direct","rpm":8123,"speed":94}'
```

Success response:

```json
{
  "status": true,
  "message": "success"
}
```

## Coalescing Semantics

The service stores each POST as a telemetry row with a JSON `data` object. The
snapshot API then coalesces rows inside the requested `time_window`:

- Each top-level key in `data` is considered independently.
- For each key, the newest value within the window wins.
- Nested objects are treated as whole values; nested fields are not merged.
- `null` is a valid latest value if it is the newest value for a key.
- Fields disappear from snapshots once no value for that key exists inside the
  requested window.

This means multiple producers can send partial messages, and consumers can read
one current-state object:

```text
POST {"rpm":8123}
POST {"speed":94}
GET  /api/telemetry?time_window=120
```

returns:

```json
{
  "status": true,
  "message": "ok",
  "time": "2026-05-19T23:41:36Z",
  "data": {
    "rpm": 8123,
    "speed": 94
  }
}
```

## OBS Browser Source Notes

For OBS overlays, prefer the websocket endpoint so the browser source updates
without polling:

```text
wss://racing.gus.is/api/telemetry/ws?time_window=86400
```

Use a short window, such as `120`, for live race overlays where stale values
should disappear quickly. Use a longer window, such as `86400`, when developing
or testing without live telemetry streaming.

## Operational Checks

Basic endpoint checks:

```bash
curl -s https://racing.gus.is/api/telemetry | jq
curl -s 'https://racing.gus.is/api/telemetry?time_window=86400' | jq
```

Failure hints:

- `502` from Caddy means the reverse proxy cannot reach racetelem on the local
  upstream.
- `500` with `Error while fetching telemetry state` means the request reached
  racetelem; check `journalctl -u racetelem`.
- `400` means the request was understood but a parameter, usually
  `time_window`, is invalid.
