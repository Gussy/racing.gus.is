#!/usr/bin/env bash
set -euo pipefail

RACETELEM_SRC="${RACETELEM_SRC:-$HOME/Development/racetelem}"
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/ansible/files"

if [ ! -d "$RACETELEM_SRC" ]; then
    echo "Error: racetelem source not found at $RACETELEM_SRC"
    echo "Set RACETELEM_SRC to the correct path"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "Building racetelem for linux/amd64..."
cd "$RACETELEM_SRC"
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$OUTPUT_DIR/racetelem" ./cmd/racetelem

echo "Built: $OUTPUT_DIR/racetelem"
file "$OUTPUT_DIR/racetelem"
