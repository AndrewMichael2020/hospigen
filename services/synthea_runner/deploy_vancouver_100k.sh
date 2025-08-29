#!/usr/bin/env bash
set -euo pipefail
# Build & deploy Cloud Run Job for 100K patients in Greater Vancouver Area, BC with CSV output

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

IMAGE="gcr.io/${PROJECT_ID}/synthea-runner:vancouver-100k"
JOB_NAME="synthea-runner-vancouver-100k"

echo "Deploying Synthea runner for 100K patients in Greater Vancouver Area, BC"
echo "Target: Vancouver, British Columbia"
echo "Count: 100,000 patients"
echo "Output: CSV + FHIR"

# Ensure APIs
gcloud services enable run.googleapis.com cloudbuild.googleapis.com healthcare.googleapis.com --project "$PROJECT_ID"

# Build (use root context + Dockerfile path via config)
echo "Building container image..."
gcloud builds submit --config services/synthea_runner/cloudbuild.yaml \
  --substitutions _IMAGE="$IMAGE" \
  --project "$PROJECT_ID" \
  .

# Delete existing job if it exists
echo "Cleaning up existing job..."
gcloud run jobs delete "$JOB_NAME" --region "$REGION" --quiet --project "$PROJECT_ID" 2>/dev/null || true

# Create job with optimized settings for 100K patients
echo "Creating Cloud Run job..."
gcloud run jobs create "$JOB_NAME" \
  --image "$IMAGE" \
  --region "$REGION" \
  --project "$PROJECT_ID" \
  --memory=8Gi \
  --cpu=4 \
  --max-retries=1 \
  --task-timeout=7200s \
  --parallelism=1 \
  --set-env-vars 'MODE=job,FHIR_STORE='"${STORE_ID_PATH}"',COUNTRY=CA,PROVINCE=BC,CITY=Vancouver,COUNT=100000,MAX_QPS=5,DRY_RUN=false,SEED=42'

# Grant Healthcare role to default compute SA (best-effort)
echo "Setting up permissions..."
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}" \
  --role="roles/healthcare.fhirResourceEditor" \
  --quiet || true

echo ""
echo "Job created successfully!"
echo "To execute the job run:"
echo "  gcloud run jobs execute $JOB_NAME --region $REGION --project $PROJECT_ID"
echo ""
echo "To monitor execution:"
echo "  gcloud run jobs executions list --job=$JOB_NAME --region=$REGION --project=$PROJECT_ID"
echo ""
echo "Job configuration:"
echo "  - Location: Vancouver, British Columbia, Canada"
echo "  - Patient count: 100,000"
echo "  - Memory: 8GB"
echo "  - CPU: 4 vCPU"
echo "  - Timeout: 2 hours"
echo "  - Seed: 42 (for reproducibility)"
echo "  - Output: CSV files + FHIR bundles"

# Optionally execute immediately
read -p "Execute the job now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Executing job..."
    gcloud run jobs execute "$JOB_NAME" --region "$REGION" --project "$PROJECT_ID"
    echo ""
    echo "Job execution started. Monitor progress with:"
    echo "  gcloud run jobs executions list --job=$JOB_NAME --region=$REGION --project=$PROJECT_ID"
    echo "  gcloud logs read --project=$PROJECT_ID"
else
    echo "Job created but not executed. Run the execute command above when ready."
fi