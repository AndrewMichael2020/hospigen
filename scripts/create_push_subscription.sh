#!/usr/bin/env bash
set -euo pipefail
if [ -f .env ]; then source .env; fi
: "${PROJECT_ID:?}"
: "${REGION:?}"
: "${BRIDGE_SERVICE:?}"
: "${BRIDGE_URL:?}"
: "${PUSH_SA:?}"

gcloud config set project "$PROJECT_ID" >/dev/null

# Allow push SA to invoke Bridge
gcloud run services add-iam-policy-binding "$BRIDGE_SERVICE"   --region "$REGION"   --member="serviceAccount:${PUSH_SA}"   --role="roles/run.invoker"

# Create DLQ if missing (defensive)
gcloud pubsub topics create dlq.fhir 2>/dev/null || true

# Create push subscription from fhir.changes to Bridge
gcloud pubsub subscriptions create fhir.changes.to-bridge   --topic=fhir.changes   --push-endpoint="${BRIDGE_URL}/pubsub/push"   --push-auth-service-account="${PUSH_SA}"   --dead-letter-topic="projects/${PROJECT_ID}/topics/dlq.fhir"   --max-delivery-attempts=5 || echo "Subscription exists: fhir.changes.to-bridge"

echo "Push subscription created: fhir.changes.to-bridge -> ${BRIDGE_URL}/pubsub/push"
