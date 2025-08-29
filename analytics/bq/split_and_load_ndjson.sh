#!/usr/bin/env bash
set -euo pipefail

# Split a local NDJSON file into small parts, upload to GCS, and load into BigQuery
# Usage: split_and_load_ndjson.sh --local /path/to/file.ndjson --gcs-prefix gs://bucket/processed_resources/splits/name --dataset DATASET [-p PROJECT] [--location]

LOCAL=""
GCS_PREFIX=""
DATASET=""
PROJECT_ID=""
LOCATION="northamerica-northeast1"
LINES_PER_FILE=200

usage(){
  cat <<'EOF'
Usage: split_and_load_ndjson.sh --local /tmp/file.ndjson --gcs-prefix gs://bucket/processed_resources/splits/name --dataset synthea_raw [-p PROJECT] [--location] [--lines N]

Splits local NDJSON into small files, uploads to GCS prefix, then loads all parts into DATASET.raw_records_stg
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) LOCAL="$2"; shift 2;;
    --gcs-prefix) GCS_PREFIX="$2"; shift 2;;
    --dataset) DATASET="$2"; shift 2;;
    -p|--project) PROJECT_ID="$2"; shift 2;;
    --location) LOCATION="$2"; shift 2;;
    --lines) LINES_PER_FILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$LOCAL" || -z "$GCS_PREFIX" || -z "$DATASET" ]]; then
  usage; exit 1
fi

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
fi

if [[ ! -f "$LOCAL" ]]; then
  echo "Local file not found: $LOCAL" >&2; exit 2
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Splitting $LOCAL into parts of $LINES_PER_FILE lines under $TMPDIR"
split -l "$LINES_PER_FILE" -d --additional-suffix=.ndjson "$LOCAL" "$TMPDIR/part_"

echo "Uploading parts to $GCS_PREFIX/"
for f in "$TMPDIR"/*.ndjson; do
  base=$(basename "$f")
  gsutil cp "$f" "$GCS_PREFIX/$base"
done

echo "Running BigQuery load across parts"
DS="${PROJECT_ID}.${DATASET}"
GLOB="$GCS_PREFIX/*.ndjson"

echo "Ensure dataset $DS exists"
if ! bq --location="$LOCATION" show "$DS" >/dev/null 2>&1; then
  bq --location="$LOCATION" mk --dataset "$DS"
fi

echo "Loading into ${DS}.raw_records_stg from $GLOB"
bq --location="$LOCATION" load --source_format=NEWLINE_DELIMITED_JSON --autodetect --replace "${DS}.raw_records_stg" "$GLOB" || true

echo "If load failed, check BigQuery job errors; individual parts are under $GCS_PREFIX/ to isolate the bad part."

exit 0
