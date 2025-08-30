#!/usr/bin/env bash
set -euo pipefail

# Stage per-patient NDJSON files into BigQuery and materialize a patients table.
# Usage: ./stage_and_materialize_patients.sh --bucket <bucket> --prefix <prefix> [--project hospigen] [--location northamerica-northeast1]

PROJECT=${PROJECT:-hospigen}
DATASET=${DATASET:-synthea_raw}
LOCATION=${LOCATION:-northamerica-northeast1}
BUCKET=""
PREFIX=""
MODE=${MODE:-replace} # replace|append

usage(){
  cat <<EOF
Usage: $0 --bucket <bucket> --prefix <prefix>

Example:
  $0 --bucket synthea-raw-hospigen --prefix patients/500_v1_2025-08-29_2025-08-29_215505Z

This will:
  - ensure dataset ${PROJECT}:${DATASET} exists
  - create (if missing) a single-column staging table ${PROJECT}.${DATASET}.raw_records_stg (raw:JSON)
  - load all NDJSON files matching gs://<bucket>/<prefix>/*.ndjson into the staging table
  - create or replace a materialized `patients` table from the JSON in staging
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --project) PROJECT="$2"; shift 2;;
    --dataset) DATASET="$2"; shift 2;;
    --location) LOCATION="$2"; shift 2;;
  --skip-load) SKIP_LOAD=true; shift 1;;
    --mode) MODE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$BUCKET" || -z "$PREFIX" ]]; then
  usage; exit 2
fi

SKIP_LOAD=${SKIP_LOAD:-false}

GLOB="gs://${BUCKET}/${PREFIX}/*.ndjson"
DS="${PROJECT}.${DATASET}"
FULL_DS="${PROJECT}:${DATASET}"

echo "1) Ensure dataset exists: ${DS} in ${LOCATION}"
if ! bq --location="$LOCATION" show "${FULL_DS}" >/dev/null 2>&1; then
  echo "Creating dataset ${DS}..."
  bq --location="$LOCATION" mk --dataset "${FULL_DS}"
fi

echo "2) Ensure staging table ${DS}.raw_records_stg exists (single column raw:JSON)"
if ! bq --location="$LOCATION" show "${FULL_DS}.raw_records_stg" >/dev/null 2>&1; then
  bq --location="$LOCATION" mk --table "${FULL_DS}.raw_records_stg" raw:JSON
fi

# Helpful quick check (prints first line of one NDJSON object) - change sample file name if you want
echo "Quick tip: to inspect one uploaded file, run locally:"
echo "  gsutil cat ${GLOB} | head -n1"

if [[ "$SKIP_LOAD" == "true" ]]; then
  echo "SKIP_LOAD set: skipping bq load phase. Assuming staging table already contains files from gs://$BUCKET/$PREFIX"
else
  echo "3) Loading NDJSON files from ${GLOB} into ${DS}.raw_records_stg (one file at a time)"

  # list files and skip any already-wrapped files
  FILES=$(gsutil ls "gs://${BUCKET}/${PREFIX}/*.ndjson" 2>/dev/null || true)
  if [[ -z "$FILES" ]]; then
    echo "No NDJSON files found at gs://${BUCKET}/${PREFIX}"
  else
    for f in $FILES; do
      # skip files that look already wrapped
      if [[ "$f" == *-wrapped.ndjson ]]; then
        echo "Skipping already-wrapped file $f"
        continue
      fi
      echo "Processing $f"
      fname=$(basename "$f")
      # use a per-file wrapped prefix so the helper wraps and loads only this file
      wrapped_prefix="${PREFIX}/${fname%.ndjson}_wrapped"
      bash "$(dirname "$0")/wrap_and_load_raw_json.sh" --bucket "$BUCKET" --prefix "$PREFIX" --wrapped-prefix "$wrapped_prefix" --project "$PROJECT" --location "$LOCATION"
    done
  fi

  echo "All per-file loads submitted — check BigQuery job outputs for errors if any."
fi

echo "4) Materialize patients table from staging (upsert/merge into ${PROJECT}.${DATASET}.patients)"

# Ensure patients table exists with required schema (patient_id STRING unique key, raw JSON, ingestion_ts, generated_ts)
if ! bq --location="$LOCATION" show "${PROJECT}:${DATASET}.patients" >/dev/null 2>&1; then
  echo "Creating table ${PROJECT}.${DATASET}.patients..."
  bq --location="$LOCATION" mk --table "${PROJECT}:${DATASET}.patients" \
    patient_id:STRING,raw:JSON,ingestion_ts:TIMESTAMP,generated_ts:TIMESTAMP
fi
# Ensure the table has ingestion_ts and generated_ts columns (add if missing). Use SQL ALTER TABLE and ignore errors.
echo "Ensuring patients table has ingestion_ts and generated_ts columns (idempotent)"
# Ensure ingestion_ts column exists
bq --location="$LOCATION" --project_id="$PROJECT" query --use_legacy_sql=false "ALTER TABLE ${PROJECT}.${DATASET}.patients ADD COLUMN IF NOT EXISTS ingestion_ts TIMESTAMP;" || true
# Ensure generated_ts column exists
bq --location="$LOCATION" --project_id="$PROJECT" query --use_legacy_sql=false "ALTER TABLE ${PROJECT}.${DATASET}.patients ADD COLUMN IF NOT EXISTS generated_ts TIMESTAMP;" || true

cat <<SQL > /tmp/materialize_patients.sql
# Merge (upsert) patient records from staging into patients table.
# Use GROUP BY + ANY_VALUE to ensure at most one source row per patient_id
MERGE ${PROJECT}.${DATASET}.patients T
USING (
  SELECT
    patient_id,
    ANY_VALUE(raw) AS raw,
    ANY_VALUE(generated_ts) AS generated_ts,
    CURRENT_TIMESTAMP() AS ingestion_ts
  FROM (
    SELECT
      COALESCE(JSON_EXTRACT_SCALAR(raw, '$.id'), JSON_EXTRACT_SCALAR(raw, '$.raw.id')) AS patient_id,
      raw,
    SAFE_CAST(COALESCE(JSON_EXTRACT_SCALAR(raw, '$.meta.generated'), JSON_EXTRACT_SCALAR(raw, '$.raw.meta.generated')) AS TIMESTAMP) AS generated_ts
    FROM ${PROJECT}.${DATASET}.raw_records_stg
    WHERE COALESCE(JSON_EXTRACT_SCALAR(raw, '$.resourceType'), JSON_EXTRACT_SCALAR(raw, '$.raw.resourceType')) = 'Patient'
  )
  GROUP BY patient_id
) S
ON T.patient_id = S.patient_id
WHEN MATCHED THEN
  UPDATE SET raw = S.raw, ingestion_ts = S.ingestion_ts, generated_ts = S.generated_ts
WHEN NOT MATCHED THEN
  INSERT (patient_id, raw, ingestion_ts, generated_ts)
  VALUES (S.patient_id, S.raw, S.ingestion_ts, S.generated_ts);
SQL

bq --project_id="$PROJECT" --location="$LOCATION" query --use_legacy_sql=false < /tmp/materialize_patients.sql
rm -f /tmp/materialize_patients.sql

echo "Materialized (merged) table: ${PROJECT}.${DATASET}.patients"

echo "Done."
