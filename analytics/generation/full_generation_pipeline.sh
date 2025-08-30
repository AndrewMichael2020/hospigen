#!/usr/bin/env bash
set -euo pipefail

# Full generation pipeline using the renamed step scripts under analytics/generation
BUCKET=${BUCKET:-synthea-raw-hospigen}
TOTAL=${TOTAL:-2}
BATCH_SIZE=${BATCH_SIZE:-1}
PROJECT=${PROJECT:-hospigen}
LOCATION=${LOCATION:-northamerica-northeast1}

TIMESTAMP=$(date -u +%Y-%m-%d_%H%M%SZ)
PREFIX="patients/${TIMESTAMP}"

echo "Step 1/3: Generate $TOTAL patients and upload to gs://$BUCKET/$PREFIX"
python3 analytics/generation/step_1_generate_data.py --total "$TOTAL" --batch-size "$BATCH_SIZE" --upload --gcs-bucket "$BUCKET" --gcs-prefix "$PREFIX"

echo "Step 2/3: Wrap NDJSON and load into staging"
bash analytics/generation/step_2_wrap_and_load.sh --bucket "$BUCKET" --prefix "$PREFIX" --project "$PROJECT" --location "$LOCATION"

echo "Step 3/3: Materialize patients table from staging"
bash analytics/generation/step_3_materialize_tables.sh --bucket "$BUCKET" --prefix "$PREFIX" --project "$PROJECT" --location "$LOCATION"

echo "Full pipeline complete."
