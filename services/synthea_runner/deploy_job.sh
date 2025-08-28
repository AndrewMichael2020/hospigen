#!/usr/bin/env bash
set -euo pipefail
# Build & deploy Cloud Run Job then execute once for Surrey, BC (200 patients)

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT_DIR"

set -a; source "$ROOT_DIR/.env"; set +a
: "${PROJECT_ID:?}"
: "${REGION:?}"
if [[ -z "${STORE_ID_PATH:-}" ]]; then
  # Try to construct from DATASET or DATASET_ID along with STORE_ID
  if [[ -n "${STORE_ID:-}" ]]; then
    if [[ -n "${DATASET:-}" ]]; then
      STORE_ID_PATH="projects/${PROJECT_ID}/locations/${REGION}/datasets/${DATASET}/fhirStores/${STORE_ID}"
    elif [[ -n "${DATASET_ID:-}" ]]; then
      STORE_ID_PATH="projects/${PROJECT_ID}/locations/${REGION}/datasets/${DATASET_ID}/fhirStores/${STORE_ID}"
    fi
  fi
  if [[ -z "${STORE_ID_PATH:-}" ]]; then
    echo "ERROR: STORE_ID_PATH not set. Run scripts/fill_env.sh or export DATASET_ID and STORE_ID." >&2
    exit 1
  fi
fi

IMAGE="gcr.io/${PROJECT_ID}/synthea-runner:surrey-200"

# Ensure APIs
gcloud services enable run.googleapis.com cloudbuild.googleapis.com healthcare.googleapis.com --project "$PROJECT_ID"

# Build (use root context + Dockerfile path via config)
gcloud builds submit --config services/synthea_runner/cloudbuild.yaml \
  --substitutions _IMAGE="$IMAGE" \
  --project "$PROJECT_ID" \
  .

# Create/Update job
gcloud run jobs delete synthea-runner-surrey-200 --region "$REGION" --quiet --project "$PROJECT_ID" || true

gcloud run jobs create synthea-runner-surrey-200 \
  --image "$IMAGE" \
  --region "$REGION" \
  --project "$PROJECT_ID" \
  --memory=4Gi \
  --cpu=2 \
  --max-retries=0 \
  --task-timeout=3600s \
  --set-env-vars 'MODE=job,FHIR_STORE='"${STORE_ID_PATH}"',COUNTRY=CA,PROVINCE=BC,CITY=Surrey,COUNT=200,MAX_QPS=3,DRY_RUN=false'

# Grant Healthcare role to default compute SA (best-effort)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}" \
  --role="roles/healthcare.fhirResourceEditor" \
  --quiet || true

# Execute once
gcloud run jobs execute synthea-runner-surrey-200 --region "$REGION" --project "$PROJECT_ID"
