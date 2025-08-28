#!/usr/bin/env bash
set -euo pipefail

# --- env bootstrap ---
function need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}
need gcloud; need jq; need curl; need base64

# Load .env if present
if [[ -f ".env" ]]; then
  set -a; source .env; set +a
fi

# Fallbacks
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-northamerica-northeast1}"
DATASET_ID="${DATASET_ID:-hospitalgen-ds}"
STORE_ID="${STORE_ID:-hospitalgen-fhir}"

[[ -n "$PROJECT_ID" ]] || { echo "PROJECT_ID is empty"; exit 1; }

FHIR_BASE="https://healthcare.googleapis.com/v1/projects/${PROJECT_ID}/locations/us-central1/datasets/${DATASET_ID}/fhirStores/${STORE_ID}/fhir"

# Make gcloud explicit
gcloud config set project "$PROJECT_ID" >/dev/null

function log() { printf "\n\033[1;34m# %s\033[0m\n" "$*"; }
function pass() { printf "\033[1;32mPASS\033[0m %s\n" "$*"; }
function fail() { printf "\033[1;31mFAIL\033[0m %s\n" "$*"; exit 1; }

# --- helpers ---
function ensure_topic() {
  local topic="$1"
  gcloud pubsub topics create "$topic" >/dev/null 2>&1 || true
}

function ensure_sub() {
  local sub="$1" topic="$2"
  gcloud pubsub subscriptions create "$sub" --topic="$topic" >/dev/null 2>&1 || true
}

function token() {
  gcloud auth print-access-token
}

# Upsert Patient/ca-100
function ensure_patient() {
  local tok="$(token)"
  curl -sX PUT "${FHIR_BASE}/Patient/ca-100" \
    -H "Authorization: Bearer ${tok}" -H "Content-Type: application/fhir+json" \
    -d '{"resourceType":"Patient","id":"ca-100","name":[{"family":"Doe","given":["Jane"]}]}' >/dev/null
}

# Decode base64 message.data entries to JSON envelopes
function pull_and_decode() {
  local sub="$1" limit="${2:-10}"
  gcloud pubsub subscriptions pull "$sub" --auto-ack --limit="$limit" --format=json \
  | jq -r '((.receivedMessages? // .) | .[]?) | .message.data? // empty' \
  | while read -r B64; do
      if [[ -n "$B64" ]]; then
        printf "%s" "$B64" | base64 -d 2>/dev/null || true
        printf "\n"
      fi
    done
}

# Quick wiring checks with tips
function check_wiring() {
  log "Config: PROJECT_ID=${PROJECT_ID}, DATASET_ID=${DATASET_ID}, STORE_ID=${STORE_ID}, FHIR_BASE=${FHIR_BASE}"
  local configured_topic
  configured_topic="$(gcloud healthcare fhir-stores describe "${STORE_ID}" --dataset="${DATASET_ID}" --location="us-central1" --format="value(notificationConfig.pubsubTopic)" 2>/dev/null || true)"
  local expected_topic="projects/${PROJECT_ID}/topics/fhir.changes"
  if [[ -z "$configured_topic" || "$configured_topic" != "$expected_topic" ]]; then
    echo "Hint: FHIR notifications not set to ${expected_topic}."
    echo "Run: bash scripts/setup_fhir_notifications.sh"
  else
    echo "FHIR notifications OK: ${configured_topic}"
  fi

  local push_url="${BRIDGE_URL:-}"
  if [[ -z "$push_url" ]]; then
    echo "Hint: BRIDGE_URL is not set. Source .env or set it."
  else
    echo "Bridge URL: ${push_url}"
  fi

  if ! gcloud pubsub subscriptions describe fhir.changes.to-bridge >/dev/null 2>&1; then
    echo "Hint: Push subscription fhir.changes.to-bridge missing."
    echo "Run: bash scripts/create_push_subscription.sh"
  else
    local endpoint
    endpoint="$(gcloud pubsub subscriptions describe fhir.changes.to-bridge --format='value(pushConfig.pushEndpoint)' 2>/dev/null || true)"
    echo "Push sub endpoint: ${endpoint:-<none>}"
    if [[ -n "$push_url" && "$endpoint" != "${push_url}/pubsub/push" ]]; then
      echo "Hint: Push endpoint mismatch. Expected ${push_url}/pubsub/push"
    fi
  fi
}

# Wait until a decoded envelope on sub has .resource_id == wanted
function wait_for_resource() {
  local sub="$1" wanted="$2" timeout="${3:-60}"
  local start=$(date +%s)
  while true; do
    local now=$(date +%s)
    if (( now - start > timeout )); then
      echo "Timed out waiting for resource_id=${wanted} on ${sub}"
      echo "Recent messages (topic, resource_type, resource_id):"
      pull_and_decode "$sub" 10 | jq -r '[.topic,.resource_type,.resource_id]|@tsv' 2>/dev/null | tail -n 10 || true
      echo "Troubleshooting:"
      echo "  1) Verify FHIR notifications: bash scripts/setup_fhir_notifications.sh"
      echo "  2) Verify push sub:          bash scripts/create_push_subscription.sh"
      echo "  3) Bridge health:             curl -s ${BRIDGE_URL}/health"
      fail "No matching message found on ${sub}"
    fi
    local hit="$(pull_and_decode "$sub" 10 | jq -r --arg id "$wanted" 'select(.resource_id==$id) | .resource_id' | head -n1 || true)"
    if [[ "$hit" == "$wanted" ]]; then
      pass "Found resource_id=${wanted} on ${sub}"
      return 0
    fi
    sleep 2
  done
}

# Non-fatal variant: returns 0 if found, 1 on timeout, with diagnostics
function wait_for_resource_try() {
  local sub="$1" wanted="$2" timeout="${3:-60}"
  local start=$(date +%s)
  while true; do
    local now=$(date +%s)
    if (( now - start > timeout )); then
      echo "Timed out waiting for resource_id=${wanted} on ${sub}"
      echo "Recent messages (topic, resource_type, resource_id):"
      pull_and_decode "$sub" 10 | jq -r '[.topic,.resource_type,.resource_id]|@tsv' 2>/dev/null | tail -n 10 || true
      return 1
    fi
    local hit="$(pull_and_decode "$sub" 10 | jq -r --arg id "$wanted" 'select(.resource_id==$id) | .resource_id' | head -n1 || true)"
    if [[ "$hit" == "$wanted" ]]; then
      pass "Found resource_id=${wanted} on ${sub}"
      return 0
    fi
    sleep 2
  done
}
