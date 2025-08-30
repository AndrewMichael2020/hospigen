#!/usr/bin/env bash
set -euo pipefail

# Wrap NDJSON resource lines into {"raw": <resource>} then upload to a wrapped prefix and load into BigQuery staging
# Usage: step_2_wrap_and_load.sh --bucket <bucket> --prefix <prefix> [--wrapped-prefix <wrapped_prefix>] [--project hospigen] [--location northamerica-northeast1]

PROJECT=${PROJECT:-hospigen}
BUCKET=""
PREFIX=""
WRAPPED_PREFIX=""
FILE=""
LOCATION=${LOCATION:-northamerica-northeast1}

usage(){
  cat <<EOF
Usage: $0 --bucket <bucket> --prefix <prefix> [--wrapped-prefix <wrapped_prefix>] [--file <filename>]

This script wraps each NDJSON resource line in the files at gs://<bucket>/<prefix>/*.ndjson
into wrapped NDJSON with each line: {"raw": <resource>} and writes them to a new prefix
then loads them into ${PROJECT}.synthea_raw.raw_records_stg via bq load.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --wrapped-prefix) WRAPPED_PREFIX="$2"; shift 2;;
    --file) FILE="$2"; shift 2;;
    --project) PROJECT="$2"; shift 2;;
    --location) LOCATION="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$BUCKET" || ( -z "$PREFIX" && -z "$FILE" ) ]]; then
  usage; exit 2
fi

if [[ -z "$WRAPPED_PREFIX" ]]; then
  if [[ -n "$PREFIX" ]]; then
    WRAPPED_PREFIX="${PREFIX}_wrapped"
  else
    WRAPPED_PREFIX="wrapped"
  fi
fi

TMPDIR=$(mktemp -d)

if [[ -n "$FILE" ]]; then
  echo "Downloading single NDJSON file gs://$BUCKET/$PREFIX/$FILE to $TMPDIR"
  gsutil -q cp "gs://$BUCKET/$PREFIX/$FILE" "$TMPDIR/" || true
else
  echo "Downloading NDJSON files from gs://$BUCKET/$PREFIX/*.ndjson to $TMPDIR"
  gsutil -m cp "gs://$BUCKET/$PREFIX/*.ndjson" "$TMPDIR/" || true
fi

for f in "$TMPDIR"/*.ndjson; do
  [[ -f "$f" ]] || continue
  base=$(basename "$f")
  wrapped="$TMPDIR/wrapped_${base}"
  echo "Wrapping $base -> $(basename "$wrapped")"
  # wrap every non-empty line
  awk 'BEGIN{ORS=""} {if(length($0)>0) print "{\"raw\":" $0 "}\n"}' "$f" > "$wrapped"

  wrapped_gs_path="gs://$BUCKET/$WRAPPED_PREFIX/$(basename "$wrapped")"
  # skip upload/load if wrapped file already exists
  if gsutil -q stat "$wrapped_gs_path" 2>/dev/null; then
    echo "Wrapped file already exists: $wrapped_gs_path - skipping upload/load"
    continue
  fi

  echo "Uploading wrapped file to $wrapped_gs_path"
  gsutil -q cp "$wrapped" "$wrapped_gs_path"

  echo "Loading wrapped NDJSON into BigQuery staging table ${PROJECT}:synthea_raw.raw_records_stg (append for this file)"
  bq --location="$LOCATION" load --source_format=NEWLINE_DELIMITED_JSON "${PROJECT}:synthea_raw.raw_records_stg" "$wrapped_gs_path" raw:JSON || true
done

echo "Cleaning temporary files"
rm -rf "$TMPDIR"

echo "Done."
