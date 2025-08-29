#!/usr/bin/env bash
set -euo pipefail

# Upload a local Synthea CSV root (containing one or more run_* folders) to GCS,
# then load into BigQuery using the analytics/bq loader.

usage() {
  cat <<'EOF'
Usage: run_pipeline_from_local_csv.sh --dataset DATASET --bucket gs://BUCKET [-p PROJECT_ID] --csv-root /local/path

Examples:
  ./analytics/run_pipeline_from_local_csv.sh \
    --dataset hc_demo \
    --bucket gs://synthea-raw-$PROJECT_ID \
    --csv-root ./synthea/output/csv
EOF
}

PROJECT_ID=""
DATASET=""
BUCKET=""
CSV_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dataset) DATASET="$2"; shift 2;;
    --bucket) BUCKET="$2"; shift 2;;
    --csv-root) CSV_ROOT="$2"; shift 2;;
    -p|--project) PROJECT_ID="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
set -a; if [[ -f "$ROOT_DIR/.env" ]]; then source "$ROOT_DIR/.env"; fi; set +a

PROJECT_ID="${PROJECT_ID:-${PROJECT_ID:-}}"
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
fi
if [[ -z "$PROJECT_ID" ]]; then
  echo "PROJECT_ID not set (flag or .env or gcloud)." >&2
  exit 1
fi

if [[ -z "$DATASET" || -z "$BUCKET" || -z "$CSV_ROOT" ]]; then
  usage; exit 1
fi

if [[ ! -d "$CSV_ROOT" ]]; then
  echo "CSV root not found: $CSV_ROOT" >&2
  exit 1
fi

# Create bucket if needed (regional, matches REGION if available)
REGION=${REGION:-northamerica-northeast1}
if ! gsutil ls -b "$BUCKET" >/dev/null 2>&1; then
  gsutil mb -l "$REGION" "$BUCKET"
fi

# Copy run_* folders (flat or nested under csv/)
set +e
RUN_DIRS=$(find "$CSV_ROOT" -maxdepth 2 -type d -name 'run_*')
set -e
if [[ -z "$RUN_DIRS" ]]; then
  echo "No run_* directories found under $CSV_ROOT" >&2
  exit 1
fi

echo "Uploading CSV runs to $BUCKET ..."
while IFS= read -r d; do
  gsutil -m cp -r "$d" "$BUCKET/"
done <<< "$RUN_DIRS"

GCS_GLOB="$BUCKET/run_*"

"$ROOT_DIR"/analytics/bq/load_from_gcs.sh --dataset "$DATASET" --gcs "$GCS_GLOB" --project "$PROJECT_ID"

echo "Done."
