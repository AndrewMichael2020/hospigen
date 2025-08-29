#!/usr/bin/env bash
set -euo pipefail
if [ -f .env ]; then source .env; fi
: "${PROJECT_ID:?}"
: "${DATASET_ID:?}"
: "${STORE_ID:?}"

gcloud config set project "$PROJECT_ID" >/dev/null

# Use correct flag for notifications
gcloud healthcare fhir-stores update "$STORE_ID" \
  --dataset="$DATASET_ID" \
  --pubsub-topic="projects/${PROJECT_ID}/topics/fhir.changes"

echo "FHIR store notifications set to projects/${PROJECT_ID}/topics/fhir.changes"
