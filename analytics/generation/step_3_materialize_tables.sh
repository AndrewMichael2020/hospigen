#!/usr/bin/env bash
set -euo pipefail

# Stage per-patient NDJSON files into BigQuery and materialize a patients table.
# Usage: step_3_materialize_tables.sh --bucket <bucket> --prefix <prefix> [--project hospigen] [--location northamerica-northeast1]

PROJECT=${PROJECT:-hospigen}
DATASET=${DATASET:-synthea_raw}
LOCATION=${LOCATION:-northamerica-northeast1}
BUCKET=""
PREFIX=""

usage(){
  cat <<EOF
Usage: $0 --bucket <bucket> --prefix <prefix>

This will:
  - ensure dataset ${PROJECT}:${DATASET} exists
  - create (if missing) a single-column staging table ${PROJECT}.${DATASET}.raw_records_stg (raw:JSON)
  - load NDJSON files matching gs://<bucket>/<prefix>/*.ndjson into the staging table
  - MERGE (upsert) into ${PROJECT}.${DATASET}.patients with ingestion_ts/generated_ts
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --project) PROJECT="$2"; shift 2;;
    --dataset) DATASET="$2"; shift 2;;
    --location) LOCATION="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$BUCKET" || -z "$PREFIX" ]]; then
  usage; exit 2
fi

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

echo "Quick tip: to inspect one uploaded file, run locally:"
echo "  gsutil cat ${GLOB} | head -n1"

echo "3) Loading NDJSON files from ${GLOB} into ${DS}.raw_records_stg (one file at a time)"

FILES=$(gsutil ls "gs://${BUCKET}/${PREFIX}/*.ndjson" 2>/dev/null || true)
if [[ -z "$FILES" ]]; then
  echo "No NDJSON files found at gs://${BUCKET}/${PREFIX}"
else
  for f in $FILES; do
    # skip files that look already-wrapped
    if [[ "$f" == *-wrapped.ndjson ]]; then
      echo "Skipping already-wrapped file $f"
      continue
    fi
    echo "Processing $f"
    fname=$(basename "$f")
    bash "$(dirname "$0")/step_2_wrap_and_load.sh" --bucket "$BUCKET" --prefix "$PREFIX" --file "$fname" --wrapped-prefix "${PREFIX}/${fname%.ndjson}_wrapped" --project "$PROJECT" --location "$LOCATION"
  done
fi

echo "All per-file loads submitted — check BigQuery job outputs for errors if any."

echo "4) Materialize (MERGE) patients table from staging"

# Create patients table if missing (overwrite allowed per user)
echo "Ensuring patients table exists with desired schema (overwrite allowed)"
bq --location="$LOCATION" --project_id="$PROJECT" query --use_legacy_sql=false "CREATE OR REPLACE TABLE ${PROJECT}.${DATASET}.patients (
  patient_id STRING,
  gender STRING,
  birth_date STRING,
  family_name STRING,
  city STRING,
  raw JSON,
  generated_ts TIMESTAMP,
  ingestion_ts TIMESTAMP
);"

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
