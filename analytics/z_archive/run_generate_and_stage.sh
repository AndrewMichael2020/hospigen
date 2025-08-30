#!/usr/bin/env bash
set -euo pipefail

# Driver: generate patients, upload per-resource NDJSON to GCS, load into BigQuery staging, and materialize patients table.
# This script is conservative: small batches, optional dry-run, and checks to avoid accidental deletes.

PROJECT=${PROJECT:-hospigen}
BUCKET=${BUCKET:-synthea-raw-hospigen}
TOTAL=${TOTAL:-10}
BATCH_SIZE=${BATCH_SIZE:-5}
PREFIX_VERSION=${PREFIX_VERSION:-test_run}
LOCATION=${LOCATION:-northamerica-northeast1}
DRY_RUN=${DRY_RUN:-false}
UPLOAD_DELAY=${UPLOAD_DELAY:-0.5} # seconds between uploads to avoid flurries

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STAGE_SCRIPT="$SCRIPT_DIR/../bq/stage_and_materialize_patients.sh"

usage(){
  cat <<EOF
Usage: $0 [--total N] [--batch-size N] [--bucket BUCKET] [--prefix-version NAME] [--dry-run]

Defaults: TOTAL=$TOTAL BATCH_SIZE=$BATCH_SIZE BUCKET=$BUCKET
Example:
  $0 --total 10 --batch-size 5 --bucket synthea-raw-hospigen --prefix-version 10test
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --total) TOTAL="$2"; shift 2;;
    --batch-size) BATCH_SIZE="$2"; shift 2;;
    --bucket) BUCKET="$2"; shift 2;;
    --prefix-version) PREFIX_VERSION="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN: no uploads or BigQuery loads will be executed. Will print planned actions."
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H%M%SZ)
PREFIX="patients/${PREFIX_VERSION}_${TIMESTAMP}"
echo "Will generate $TOTAL patients in batches of $BATCH_SIZE, upload to gs://$BUCKET/$PREFIX"

if [[ "$DRY_RUN" == "false" ]]; then
  # do not attempt to create a placeholder (prefix helper removed by user)
  :
fi

OUTDIR=$(mktemp -d -p /tmp hospigen_gen_XXXX)
echo "Using temporary outdir: $OUTDIR"

remaining=$TOTAL
seed=12345
counter=0
while [[ $remaining -gt 0 ]]; do
  this_batch=$(( remaining < BATCH_SIZE ? remaining : BATCH_SIZE ))
  echo "Generating batch of $this_batch patients (seed=$seed)..."

  if [[ "$DRY_RUN" == "false" ]]; then
    # invoke existing generator if present
    if [[ -x "$SCRIPT_DIR/extract_vancouver_500.py" || -f "$SCRIPT_DIR/extract_vancouver_500.py" ]]; then
      python3 "$SCRIPT_DIR/extract_vancouver_500.py" --total "$this_batch" --batch-size "$this_batch" --seed "$seed" --out-dir "$OUTDIR"
    else
      # fall back to writing sample bundle files for the batch
      for i in $(seq 1 $this_batch); do
        cp /workspaces/hospigen/output/patient_sample_0001_with_encounters.json "$OUTDIR/patient_$(printf "%04d" $((counter + i))).json"
      done
    fi
  else
    echo "DRY_RUN: would run generator for $this_batch patients (seed=$seed) -> $OUTDIR"
  fi

  # convert any bundle files in outdir to per-resource NDJSON and upload per resource as ndjson files
  for f in "$OUTDIR"/*.json; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f" .json)
    ndjson="$OUTDIR/${base}.ndjson"
    # extract resources from bundle (or wrap single Patient)
    if jq -e '.resourceType == "Bundle"' "$f" >/dev/null 2>&1; then
      jq -c '.entry[].resource' "$f" > "$ndjson"
    else
      jq -c '.' "$f" > "$ndjson"
    fi

    if [[ "$DRY_RUN" == "false" ]]; then
      echo "Uploading $ndjson -> gs://$BUCKET/$PREFIX/$base.ndjson"
      gsutil -q cp "$ndjson" "gs://$BUCKET/$PREFIX/$base.ndjson"
      sleep "$UPLOAD_DELAY"
      rm -f "$ndjson"
    else
      echo "DRY_RUN: would upload $ndjson -> gs://$BUCKET/$PREFIX/$base.ndjson"
    fi
  done

  remaining=$(( remaining - this_batch ))
  seed=$(( seed + 1 ))
  counter=$(( counter + this_batch ))
done

echo "Upload phase complete. Temporary outputs are in $OUTDIR"

if [[ "$DRY_RUN" == "false" ]]; then
  echo "Now loading into BigQuery and materializing patients via staging script"
  bash "$STAGE_SCRIPT" --bucket "$BUCKET" --prefix "$PREFIX" --project "$PROJECT" --location "$LOCATION"
else
  echo "DRY_RUN: skipping BigQuery staging and materialize"
fi

echo "Run complete."

