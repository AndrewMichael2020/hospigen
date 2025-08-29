#!/usr/bin/env bash
set -euo pipefail

# Load processed_resources/*.ndjson files into a single BigQuery staging table
# Usage: load_ndjson_from_gcs.sh --dataset DATASET --gcs gs://bucket/processed_resources/*.ndjson \
#        [-p PROJECT] [--location northamerica-northeast1] [--mode append|replace] [--delete-objects gs://bucket/prefix/*.ndjson] [--dry-run]

PROJECT_ID=""
DATASET=""
GCS_GLOB=""
LOCATION="northamerica-northeast1"
MODE="replace" # replace or append
DELETE_GLOB=""
DRY_RUN=false

usage(){
  cat <<'EOF'
Usage: load_ndjson_from_gcs.sh --dataset DATASET --gcs gs://bucket/processed_resources/*.ndjson [-p PROJECT] [--location]

This will load all NDJSON resource files into ${PROJECT}.${DATASET}.raw_records_stg
Options:
  --mode MODE            Load mode: "replace" (default) will replace the table, "append" will append to it.
  --delete-objects GLOB  If set, delete matching objects from GCS before loading. Use with caution.
  --dry-run              Print actions but do not perform gsutil or bq load.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dataset) DATASET="$2"; shift 2;;
    --gcs) GCS_GLOB="$2"; shift 2;;
    -p|--project) PROJECT_ID="$2"; shift 2;;
  --mode) MODE="$2"; shift 2;;
  --delete-objects) DELETE_GLOB="$2"; shift 2;;
  --dry-run) DRY_RUN=true; shift 1;;
    --location) LOCATION="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$DATASET" || -z "$GCS_GLOB" ]]; then
  usage; exit 1
fi

if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
fi
DS="${PROJECT_ID}.${DATASET}"

echo "Ensuring dataset $DS in $LOCATION ..."
if ! bq --location="$LOCATION" show "$DS" >/dev/null 2>&1; then
  bq --location="$LOCATION" mk --dataset "$DS"
fi

echo "Ensuring table ${DS}.raw_records_stg exists (single JSON column 'raw') and loading NDJSON files from $GCS_GLOB"
# Create a stable single-column staging table if it doesn't exist. This avoids BigQuery
# schema autodetection creating many incompatible tables when resource shapes vary.
if ! bq --location="$LOCATION" show "${DS}.raw_records_stg" >/dev/null 2>&1; then
  echo "Creating table ${DS}.raw_records_stg with schema raw:JSON"
  bq --location="$LOCATION" mk --table "${DS}.raw_records_stg" raw:JSON
fi

# Optional pre-load deletion of objects (useful for idempotent re-runs)
if [[ -n "$DELETE_GLOB" ]]; then
  echo "Requested deletion of GCS objects matching: $DELETE_GLOB"
  if [[ "$DRY_RUN" == true ]]; then
    echo "Dry-run: would run: gsutil -m rm \"$DELETE_GLOB\""
  else
    if ! command -v gsutil >/dev/null 2>&1; then
      echo "gsutil not found in PATH; cannot delete objects" >&2; exit 2
    fi
    echo "Deleting matching objects: $DELETE_GLOB"
    gsutil -m rm "$DELETE_GLOB" || { echo "gsutil delete failed" >&2; exit 3; }
  fi
fi

# Load into the explicit JSON column (no --autodetect). This expects NDJSON where
# each line is a JSON object representing a single resource; we recommend wrapping
# full bundles into {"raw": <resource>} prior to load if needed.
LOAD_CMD=(bq --location="$LOCATION" load --source_format=NEWLINE_DELIMITED_JSON)
if [[ "$MODE" == "replace" ]]; then
  LOAD_CMD+=(--replace "${DS}.raw_records_stg" "$GCS_GLOB" raw:JSON)
else
  LOAD_CMD+=("${DS}.raw_records_stg" "$GCS_GLOB" raw:JSON)
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "Dry-run: would run: ${LOAD_CMD[*]}"
else
  "${LOAD_CMD[@]}"
fi

echo "Done. If load failed, inspect BigQuery job errors and consider splitting the NDJSON into smaller files for isolation."

exit 0
