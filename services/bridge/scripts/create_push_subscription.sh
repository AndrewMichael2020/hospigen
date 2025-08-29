#!/usr/bin/env bash
set -euo pipefail
if [ -f .env ]; then source .env; fi
: "${PROJECT_ID:?}"
: "${REGION:?}"
: "${BRIDGE_SERVICE:?}"

# Resolve BRIDGE_URL if not provided in .env by describing the Cloud Run service
if [ -z "${BRIDGE_URL:-}" ] || [ "${BRIDGE_URL}" = "" ]; then
  echo "BRIDGE_URL not set; resolving from Cloud Run service '${BRIDGE_SERVICE}' in ${REGION}..."
  BRIDGE_URL="$(gcloud run services describe "${BRIDGE_SERVICE}" --region "${REGION}" --format='value(status.url)')"
  if [ -z "${BRIDGE_URL}" ]; then
    echo "ERROR: Could not resolve BRIDGE_URL. Set BRIDGE_URL in .env or ensure the Cloud Run service exists."
    exit 1
  fi
fi

# Default SA name
PUSH_SA="${PUSH_SA:-bridge-push@${PROJECT_ID}.iam.gserviceaccount.com}"

gcloud config set project "$PROJECT_ID" >/dev/null

# Ensure service account exists
if ! gcloud iam service-accounts describe "${PUSH_SA}" >/dev/null 2>&1; then
  echo "Creating service account: ${PUSH_SA}"
  gcloud iam service-accounts create bridge-push \
    --display-name="Hospigen Bridge Pub/Sub Push Invoker" || true
fi

# Allow push SA to invoke Bridge
gcloud run services add-iam-policy-binding "$BRIDGE_SERVICE" \
  --region "$REGION" \
  --member="serviceAccount:${PUSH_SA}" \
  --role="roles/run.invoker"

# Remove public access if present (security hardening)
HAS_PUBLIC=$(gcloud run services get-iam-policy "$BRIDGE_SERVICE" --region "$REGION" --format='json(bindings[?role==`roles/run.invoker`].members[])' | jq -r '.[]? // empty' | grep -E '^(allUsers|allAuthenticatedUsers)$' || true)
if [[ -n "$HAS_PUBLIC" ]]; then
  echo "Removing public invoker bindings from $BRIDGE_SERVICE..."
  gcloud run services remove-iam-policy-binding "$BRIDGE_SERVICE" \
    --region "$REGION" \
    --member="allUsers" \
    --role="roles/run.invoker" 2>/dev/null || true
  gcloud run services remove-iam-policy-binding "$BRIDGE_SERVICE" \
    --region "$REGION" \
    --member="allAuthenticatedUsers" \
    --role="roles/run.invoker" 2>/dev/null || true
fi

# Create DLQ if missing (defensive)
gcloud pubsub topics create dlq.fhir 2>/dev/null || true

# Compute normalized endpoint (avoid double //)
BASE_URL=${BRIDGE_URL%/}
ENDPOINT="${BASE_URL}/pubsub/push"

# Create or update push subscription from fhir.changes to Bridge
if ! gcloud pubsub subscriptions describe fhir.changes.to-bridge >/dev/null 2>&1; then
  gcloud pubsub subscriptions create fhir.changes.to-bridge \
    --topic=fhir.changes \
    --push-endpoint="${ENDPOINT}" \
    --push-auth-service-account="${PUSH_SA}" \
    --dead-letter-topic="projects/${PROJECT_ID}/topics/dlq.fhir" \
    --max-delivery-attempts=5
  echo "Push subscription created: fhir.changes.to-bridge -> ${ENDPOINT}"
else
  gcloud pubsub subscriptions update fhir.changes.to-bridge \
    --push-endpoint="${ENDPOINT}" \
    --push-auth-service-account="${PUSH_SA}" 
  echo "Push subscription updated: fhir.changes.to-bridge -> ${ENDPOINT}"
fi

# Show the effective endpoint for confirmation
gcloud pubsub subscriptions describe fhir.changes.to-bridge --format='value(pushConfig.pushEndpoint)'
