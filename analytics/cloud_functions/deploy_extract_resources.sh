#!/usr/bin/env bash
set -euo pipefail

# Deploy the Cloud Function that extracts resources from synthea batch files
# Usage: ./deploy_extract_resources.sh PROJECT BUCKET

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 PROJECT_ID BUCKET_NAME [REGION]"
  exit 2
fi

PROJECT="$1"
BUCKET="$2"
REGION="${3:-us-central1}"
FUNCTION_NAME="extract_resources_gcs"

gcloud functions deploy $FUNCTION_NAME \
  --project="$PROJECT" \
  --region="$REGION" \
  --runtime=python312 \
  --trigger-bucket="$BUCKET" \
  --entry-point=extract_resources_gcs \
  --source="$(pwd)/cloud_functions/extract_resources" \
  --set-env-vars=PROCESSED_PREFIX=processed_resources

echo "Deployed function $FUNCTION_NAME -> gs://$BUCKET/processed_resources/"
