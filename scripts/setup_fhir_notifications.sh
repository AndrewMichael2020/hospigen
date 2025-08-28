#!/usr/bin/env bash
set -euo pipefail
if [ -f .env ]; then source .env; fi
: "${PROJECT_ID:?}"
: "${DATASET_ID:?}"
: "${STORE_ID:?}"

gcloud config set project "$PROJECT_ID" >/dev/null

# Send all FHIR changes to the unified topic
gcloud healthcare fhir-stores update "$STORE_ID"   --dataset="$DATASET_ID"   --notification-config="topic=projects/${PROJECT_ID}/topics/fhir.changes"

echo "FHIR store notifications set to projects/${PROJECT_ID}/topics/fhir.changes"
