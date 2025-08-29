#!/usr/bin/env bash
set -euo pipefail

# Load Synthea CSVs from GCS into BigQuery: stage with autodetect, then CTAS into partitioned tables.

usage() {
  cat <<'EOF'
Usage: load_from_gcs.sh --dataset DATASET --gcs "gs://bucket/run_*" [-p PROJECT_ID] [--location northamerica-northeast1]

This will:
  - Create the dataset if needed
  - Load staging tables with autodetect from GCS URIs
  - Create partitioned/clustered analytical tables (CTAS)
  - Create views and an example features table
EOF
}

PROJECT_ID=""
DATASET=""
GCS_GLOB=""
LOCATION="northamerica-northeast1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dataset) DATASET="$2"; shift 2;;
    --gcs) GCS_GLOB="$2"; shift 2;;
    -p|--project) PROJECT_ID="$2"; shift 2;;
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
if [[ -z "$PROJECT_ID" ]]; then
  echo "PROJECT_ID not set (flag or gcloud)." >&2
  exit 1
fi

DS="${PROJECT_ID}.${DATASET}"

echo "Ensuring dataset $DS in $LOCATION ..."
if ! bq --location="$LOCATION" show "$DS" >/dev/null 2>&1; then
  bq --location="$LOCATION" mk --dataset "$DS"
fi

# Helper: load table with autodetect into staging
load_stg() {
  local tbl="$1"; shift
  local uri="$1"; shift
  echo "Loading staging table ${DS}.${tbl}_stg from $uri ..."
  # NOTE: this loader is for CSV-style Synthea exports. For NDJSON (per-resource
  # JSON lines) use the load_ndjson_stg helper added below or the separate
  # analytics/bq/load_ndjson_from_gcs.sh script.
  bq --location="$LOCATION" load \
     --source_format=CSV \
     --skip_leading_rows=1 \
     --allow_quoted_newlines \
     --allow_jagged_rows \
     --autodetect \
     "${DS}.${tbl}_stg" \
     "$uri"
}

# Load newline-delimited JSON (NDJSON) into a staging table. Use this for
# files produced by the extractor/cloud-function under processed_resources/*.ndjson
load_ndjson_stg() {
  local tbl="$1"; shift
  local uri="$1"; shift
  echo "Loading NDJSON staging table ${DS}.${tbl}_stg from $uri ..."
  bq --location="$LOCATION" load \
     --source_format=NEWLINE_DELIMITED_JSON \
     --autodetect \
     "${DS}.${tbl}_stg" \
     "$uri"
}

# Core tables (mirrors Synthea CSV filenames)
CORE=(patients organizations providers encounters conditions procedures observations medications immunizations allergies careplans claims imaging_studies devices)

for t in "${CORE[@]}"; do
  load_stg "$t" "${GCS_GLOB}/$t.csv"
done

echo "Materializing partitioned/clustered analytical tables ..."

# Encounters: partition by DATE(START), cluster by PATIENT, ENCOUNTERCLASS, TYPE if present
bq --location="$LOCATION" query --use_legacy_sql=false <<SQL
CREATE OR REPLACE TABLE \
  \
  \`${DS}.encounters\` \
PARTITION BY DATE(START) \
CLUSTER BY PATIENT, ENCOUNTERCLASS, TYPE AS
SELECT * FROM \
  \`${DS}.encounters_stg\`;
SQL

# Observations (partition by DATE, cluster by PATIENT, CODE)
bq --location="$LOCATION" query --use_legacy_sql=false <<SQL
CREATE OR REPLACE TABLE \
  \`${DS}.observations\` \
PARTITION BY DATE(DATE) \
CLUSTER BY PATIENT, CODE AS
SELECT * FROM \`${DS}.observations_stg\`;
SQL

# Direct copies for other entities (no partitioning)
for t in patients organizations providers conditions procedures medications immunizations allergies careplans claims imaging_studies devices; do
  bq --location="$LOCATION" query --use_legacy_sql=false <<SQL
CREATE OR REPLACE TABLE \`${DS}.${t}\` AS
SELECT * FROM \`${DS}.${t}_stg\`;
SQL
 done

echo "Creating labs-only table and views ..."

# Labs table filtered from observations
bq --location="$LOCATION" query --use_legacy_sql=false <<SQL
CREATE OR REPLACE TABLE \`${DS}.observations_lab\`
PARTITION BY DATE(DATE)
CLUSTER BY PATIENT, CODE AS
SELECT * FROM \`${DS}.observations\`
WHERE LOWER(CATEGORY) = 'laboratory';
SQL

# Views: ED and Primary Care
bq --location="$LOCATION" query --use_legacy_sql=false <<SQL
CREATE OR REPLACE VIEW \`${DS}.v_encounters_ed\` AS
SELECT * FROM \`${DS}.encounters\`
WHERE LOWER(ENCOUNTERCLASS) = 'emergency' OR LOWER(TYPE) LIKE '%emergency%';
SQL

bq --location="$LOCATION" query --use_legacy_sql=false <<SQL
CREATE OR REPLACE VIEW \`${DS}.v_encounters_pc\` AS
SELECT * FROM \`${DS}.encounters\`
WHERE LOWER(TYPE) LIKE '%primary%' OR LOWER(TYPE) LIKE '%clinic%';
SQL

echo "Creating example features table ..."
bq --location="$LOCATION" query --use_legacy_sql=false <<SQL
CREATE OR REPLACE TABLE \`${DS}.features_ed_7d\` AS
SELECT
  e.PATIENT,
  COUNTIF(o.CATEGORY='laboratory' AND o.DATE BETWEEN TIMESTAMP_SUB(e.START, INTERVAL 7 DAY) AND e.START) AS labs_last_7d,
  COUNTIF(proc.DATE BETWEEN TIMESTAMP_SUB(e.START, INTERVAL 30 DAY) AND e.START) AS procedures_last_30d,
  ANY_VALUE(p.GENDER) AS gender,
  ANY_VALUE(p.BIRTHDATE) AS birthdate,
  e.START AS ed_start
FROM \`${DS}.v_encounters_ed\` e
LEFT JOIN \`${DS}.observations\` o ON o.PATIENT = e.PATIENT
LEFT JOIN \`${DS}.procedures\` proc ON proc.PATIENT = e.PATIENT
LEFT JOIN \`${DS}.patients\` p ON p.PATIENT = e.PATIENT
GROUP BY e.PATIENT, ed_start;
SQL

echo "Done loading into ${DS}."
