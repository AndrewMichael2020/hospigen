#!/usr/bin/env bash
set -euo pipefail

# Ingest one synthea batch from GCS: download -> extract resources -> upload NDJSON

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 gs://bucket/path/to/batch.ndjson [destination-gcs-prefix]"
  exit 2
fi

BATCH_URI="$1"
DEST_PREFIX="${2:-gs://synthea-raw-hospigen/processed_resources/}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading $BATCH_URI to $TMPDIR/batch.ndjson"
gsutil cp "$BATCH_URI" "$TMPDIR/batch.ndjson"

OUT_NDJSON="$TMPDIR/resources.ndjson"
echo "Extracting resources to $OUT_NDJSON"
python3 "$(dirname "$0")/extract_resources.py" -i "$TMPDIR/batch.ndjson" -o "$OUT_NDJSON"

DEST_URI="$DEST_PREFIX$(basename "$BATCH_URI" .ndjson)-resources.ndjson"
echo "Uploading $OUT_NDJSON to $DEST_URI"
gsutil cp "$OUT_NDJSON" "$DEST_URI"

echo "Done. Uploaded resources NDJSON to: $DEST_URI"
echo "To load into BigQuery, run analytics/bq/load_ndjson_from_gcs.sh or use the SQL workflow."

exit 0
