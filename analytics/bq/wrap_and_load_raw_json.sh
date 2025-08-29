#!/usr/bin/env bash
set -euo pipefail

# Wrap each NDJSON line into {"raw": <original-object>} and load into BigQuery table with a JSON column.
# Usage: wrap_and_load_raw_json.sh --gcs gs://bucket/path/file.ndjson --dataset synthea_raw -p hospigen --table raw_records_rawjson --location northamerica-northeast1

GCS_SRC=""
PROJECT_ID=""
DATASET=""
TABLE="raw_records_rawjson"
LOCATION="northamerica-northeast1"

usage(){
  cat <<'EOF'
Usage: wrap_and_load_raw_json.sh --gcs gs://bucket/path/file.ndjson --dataset DATASET [-p PROJECT] [--table TABLENAME] [--location]

This will download the NDJSON, wrap each JSON object as {"raw": <obj>} and upload a temporary wrapped file, then load into DATASET.TABLE with schema raw:JSON.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gcs) GCS_SRC="$2"; shift 2;;
    --dataset) DATASET="$2"; shift 2;;
    -p|--project) PROJECT_ID="$2"; shift 2;;
    --table) TABLE="$2"; shift 2;;
    --location) LOCATION="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$GCS_SRC" || -z "$DATASET" ]]; then
  usage; exit 1
fi
if [[ -z "$PROJECT_ID" ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
fi
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
LOCAL_SRC="$TMPDIR/src.ndjson"
LOCAL_WRAPPED="$TMPDIR/wrapped.ndjson"

echo "Downloading $GCS_SRC -> $LOCAL_SRC"
gsutil cp "$GCS_SRC" "$LOCAL_SRC"

python3 - <<PY > /dev/null
import json
from pathlib import Path
src = Path('$LOCAL_SRC')
out = Path('$LOCAL_WRAPPED')
with src.open('rb') as f, out.open('w', encoding='utf-8') as o:
    for raw in f:
        s = raw.rstrip(b'\r\n')
        if not s.strip():
            continue
        obj = json.loads(s.decode('utf-8'))
        o.write(json.dumps({'raw': obj}, ensure_ascii=False) + '\n')
print('WROTE', out)
PY

GCS_WRAPPED="${GCS_SRC%.ndjson}-wrapped.ndjson"
echo "Uploading wrapped file to $GCS_WRAPPED"
gsutil cp "$LOCAL_WRAPPED" "$GCS_WRAPPED"

FULL_TABLE="${PROJECT_ID}:${DATASET}.${TABLE}"
echo "Loading into $FULL_TABLE with schema raw:JSON"
bq --location="$LOCATION" load --source_format=NEWLINE_DELIMITED_JSON --schema raw:JSON --replace "$FULL_TABLE" "$GCS_WRAPPED"

echo "Done. Table: $FULL_TABLE"
exit 0
