#!/usr/bin/env bash
set -euo pipefail

# Full staging pipeline (conservative, no-rush)
# 1) Generate and upload per-patient NDJSON -> gs://<bucket>/<prefix>/
# 2) Wrap those NDJSON into {"raw":...} and load into BQ staging
# 3) Materialize patients table from staging

BUCKET=${BUCKET:-synthea-raw-hospigen}
TOTAL=${TOTAL:-2}
BATCH_SIZE=${BATCH_SIZE:-1}
PREFIX_VERSION=${PREFIX_VERSION:-auto}
PROJECT=${PROJECT:-hospigen}
LOCATION=${LOCATION:-northamerica-northeast1}

if [[ "$PREFIX_VERSION" == "auto" ]]; then
  TIMESTAMP=$(date -u +%Y-%m-%d_%H%M%SZ)
  PREFIX="patients/${TIMESTAMP}"
else
  TIMESTAMP=$(date -u +%Y-%m-%d_%H%M%SZ)
  PREFIX="patients/${PREFIX_VERSION}_${TIMESTAMP}"
fi


DRY_RUN=${DRY_RUN:-false}

echo "Step 1/3: Generate $TOTAL patients and upload to gs://$BUCKET/$PREFIX"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN: would run generator: python3 analytics/scripts/extract_vancouver_500.py --total $TOTAL --batch-size $BATCH_SIZE --upload --gcs-bucket $BUCKET --gcs-prefix $PREFIX"
else
  python3 analytics/scripts/extract_vancouver_500.py --total "$TOTAL" --batch-size "$BATCH_SIZE" --upload --gcs-bucket "$BUCKET" --gcs-prefix "$PREFIX"
fi

echo "Step 2/3: Wrap NDJSON and load into staging"
WRAPPED_PREFIX="${PREFIX}_wrapped"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN: would run wrapper: bash analytics/bq/wrap_and_load_raw_json.sh --bucket $BUCKET --prefix $PREFIX --wrapped-prefix $WRAPPED_PREFIX --project $PROJECT --location $LOCATION"
else
  bash analytics/bq/wrap_and_load_raw_json.sh --bucket "$BUCKET" --prefix "$PREFIX" --wrapped-prefix "$WRAPPED_PREFIX" --project "$PROJECT" --location "$LOCATION"
fi

echo "Step 3/3: Materialize patients table from staging"
if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN: would run stage and materialize: bash analytics/bq/stage_and_materialize_patients.sh --bucket $BUCKET --prefix $WRAPPED_PREFIX --project $PROJECT --location $LOCATION"
else
  bash analytics/bq/stage_and_materialize_patients.sh --bucket "$BUCKET" --prefix "$WRAPPED_PREFIX" --project "$PROJECT" --location "$LOCATION"
fi

echo "Full pipeline complete."
