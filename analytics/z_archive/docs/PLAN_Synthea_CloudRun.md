# Plan: Generate Synthea history on Cloud Run and ingest into FHIR

Goal: Generate 200 Canadian patients (Surrey, British Columbia) once on Cloud Run and post R4 bundles to Google Cloud Healthcare FHIR Store.

## Summary
- Use a Cloud Run container (service or job) to run Synthea with Canada geography.
- Post generated transaction bundles directly to Healthcare FHIR API.
- Throttle and retry; support dry-run; log results.

## Inputs
- PROJECT_ID, REGION
- STORE_ID_PATH (from .env via scripts/fill_env.sh), or explicit FHIR_STORE path projects/<proj>/locations/<region>/datasets/<dataset>/fhirStores/<store>
- Parameters per run: province, city, count, seed (optional), dry_run (optional), max_qps

## Artifacts
- services/synthea_runner/
  - app.py: FastAPI with POST /generate (service mode)
  - runner.py: Runs Synthea, iterates bundles, posts to FHIR
  - entrypoint.py: Chooses service vs job mode
  - Dockerfile: Python + JRE + Canada resources + Synthea JAR
  - requirements.txt
  - deploy_job.sh (helper)

## Deploy & Run (Job recommended for 200 patients)
```bash
cd services/synthea_runner
# Load your .env from repo root (already created via scripts/fill_env.sh)
set -a; source ../../.env; set +a
export IMAGE="gcr.io/${PROJECT_ID}/synthea-runner:surrey-200"
# Ensure required APIs
gcloud services enable run.googleapis.com cloudbuild.googleapis.com healthcare.googleapis.com
# Build
gcloud builds submit -t "$IMAGE" .
# Create/update job (uses STORE_ID_PATH from .env)
gcloud run jobs delete synthea-runner-surrey-200 --region "$REGION" --quiet || true
gcloud run jobs create synthea-runner-surrey-200 \
  --image "$IMAGE" \
  --region "$REGION" \
  --set-env-vars MODE=job,FHIR_STORE="${STORE_ID_PATH}",PROVINCE="British Columbia",CITY="Surrey",COUNT=200,MAX_QPS=3,DRY_RUN=false
# Grant Healthcare FHIR role to default compute SA (if needed)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA}" \
  --role="roles/healthcare.fhirResourceEditor"
# Execute once
gcloud run jobs execute synthea-runner-surrey-200 --region "$REGION"
```

## Service mode (optional)
- Deploy as Cloud Run service and call POST /generate with JSON body to run ad-hoc; for larger runs prefer Jobs.

## Notes
- Container downloads Synthea JAR at build; Canada resources are copied from repo (./ca/src/main/resources) into the image.
- Rate-limit posts (max_qps) and retry 429/5xx with backoff.
- Dry-run posts nothing but still runs Synthea and reports counts.
