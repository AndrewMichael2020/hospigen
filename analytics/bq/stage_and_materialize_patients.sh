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
    --mode) MODE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$BUCKET" || -z "$PREFIX" ]]; then
  usage; exit 2
fi

GLOB="gs://${BUCKET}/${PREFIX}/*.ndjson"
DS="${PROJECT}.${DATASET}"

echo "1) Ensure dataset exists: ${DS} in ${LOCATION}"
if ! bq --location="$LOCATION" show "${DS}" >/dev/null 2>&1; then
  echo "Creating dataset ${DS}..."
  bq --location="$LOCATION" mk --dataset "${DS}"
fi

echo "2) Ensure staging table ${DS}.raw_records_stg exists (single column raw:JSON)"
if ! bq --location="$LOCATION" show "${DS}.raw_records_stg" >/dev/null 2>&1; then
  bq --location="$LOCATION" mk --table "${DS}.raw_records_stg" raw:JSON
fi

# Helpful quick check (prints first line of one NDJSON object) - change sample file name if you want
echo "Quick tip: to inspect one uploaded file, run locally:"
echo "  gsutil cat ${GLOB} | head -n1"

echo "3) Loading NDJSON files from ${GLOB} into ${DS}.raw_records_stg (mode=${MODE})"
if [[ "$MODE" == "replace" ]]; then
  echo "Running bq load --replace ..."
  bq --location="$LOCATION" load --source_format=NEWLINE_DELIMITED_JSON --replace "${DS}.raw_records_stg" "$GLOB" raw:JSON
else
  echo "Running bq load (append) ..."
  bq --location="$LOCATION" load --source_format=NEWLINE_DELIMITED_JSON "${DS}.raw_records_stg" "$GLOB" raw:JSON
fi

echo "Load submitted — check BigQuery job output for errors if any."

echo "4) Materialize patients table from staging"
cat <<'SQL' > /tmp/materialize_patients.sql
CREATE OR REPLACE TABLE `${PROJECT}.${DATASET}.patients` AS
SELECT
  COALESCE(JSON_EXTRACT_SCALAR(raw, '$.id'), JSON_EXTRACT_SCALAR(raw, '$.raw.id')) AS patient_id,
  COALESCE(JSON_EXTRACT_SCALAR(raw, '$.gender'), JSON_EXTRACT_SCALAR(raw, '$.raw.gender')) AS gender,
  COALESCE(JSON_EXTRACT_SCALAR(raw, '$.birthDate'), JSON_EXTRACT_SCALAR(raw, '$.raw.birthDate')) AS birth_date,
  COALESCE(JSON_EXTRACT_SCALAR(raw, '$.name[0].family'), JSON_EXTRACT_SCALAR(raw, '$.raw.name[0].family')) AS family_name,
  COALESCE(JSON_EXTRACT_SCALAR(raw, '$.address[0].city'), JSON_EXTRACT_SCALAR(raw, '$.raw.address[0].city')) AS city,
  raw AS raw
FROM `${PROJECT}.${DATASET}.raw_records_stg`
WHERE COALESCE(JSON_EXTRACT_SCALAR(raw, '$.resourceType'), JSON_EXTRACT_SCALAR(raw, '$.raw.resourceType')) = 'Patient';
SQL

bq --project_id="$PROJECT" --location="$LOCATION" query --use_legacy_sql=false < /tmp/materialize_patients.sql
rm -f /tmp/materialize_patients.sql

echo "Materialized table: ${PROJECT}.${DATASET}.patients"

echo "Done."
