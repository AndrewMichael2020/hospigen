#!/usr/bin/env bash
set -euo pipefail

# Wrap NDJSON resource lines into {"raw": <resource>} then upload to a wrapped prefix and load into BigQuery staging
# Usage: wrap_and_load_raw_json.sh --bucket <bucket> --prefix <prefix> [--wrapped-prefix <wrapped_prefix>] [--project hospigen] [--location northamerica-northeast1]

PROJECT=${PROJECT:-hospigen}
BUCKET=""
PREFIX=""
WRAPPED_PREFIX=""
LOCATION=${LOCATION:-northamerica-northeast1}

usage(){
  cat <<EOF
Usage: $0 --bucket <bucket> --prefix <prefix> [--wrapped-prefix <wrapped_prefix>]

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
    --project) PROJECT="$2"; shift 2;;
    --location) LOCATION="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$BUCKET" || -z "$PREFIX" ]]; then
  usage; exit 2
fi

if [[ -z "$WRAPPED_PREFIX" ]]; then
  WRAPPED_PREFIX="${PREFIX}_wrapped"
fi

TMPDIR=$(mktemp -d)
echo "Downloading NDJSON files from gs://$BUCKET/$PREFIX/*.ndjson to $TMPDIR"
gsutil -m cp "gs://$BUCKET/$PREFIX/*.ndjson" "$TMPDIR/" || true

for f in "$TMPDIR"/*.ndjson; do
  [[ -f "$f" ]] || continue
  base=$(basename "$f")
  wrapped="$TMPDIR/wrapped_${base}"
  echo "Wrapping $base -> $(basename "$wrapped")"
  # wrap every non-empty line
  awk 'BEGIN{ORS=""} {if(length($0)>0) print "{\"raw\":" $0 "}\n"}' "$f" > "$wrapped"
  echo "Uploading wrapped file to gs://$BUCKET/$WRAPPED_PREFIX/$(basename "$wrapped")"
  gsutil -q cp "$wrapped" "gs://$BUCKET/$WRAPPED_PREFIX/"
done

echo "Loading wrapped NDJSON into BigQuery staging table ${PROJECT}:synthea_raw.raw_records_stg"
bq --location="$LOCATION" load --source_format=NEWLINE_DELIMITED_JSON --replace "${PROJECT}:synthea_raw.raw_records_stg" "gs://$BUCKET/$WRAPPED_PREFIX/*.ndjson" raw:JSON

echo "Cleaning temporary files"
rm -rf "$TMPDIR"

echo "Done."
