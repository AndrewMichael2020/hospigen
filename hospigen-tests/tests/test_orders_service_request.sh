#!/usr/bin/env bash
set -euo pipefail

# ---------- Config (env overrides allowed) ----------
PROJECT_ID="${PROJECT_ID:-hospigen}"
REGION="${REGION:-us-central1}"
DATASET="${DATASET:-hospitalgen-ds}"
FHIR_STORE="${FHIR_STORE:-hospitalgen-fhir}"
TOPIC="${ORDERS_CREATED_TOPIC:-orders.created}"   # Bridge env should point ORDERS_CREATED_TOPIC to this
PATIENT_ID="${PATIENT_ID:-ca-100}"                # ensure_patient() below will create if missing

FHIR_BASE="https://healthcare.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/datasets/${DATASET}/fhirStores/${FHIR_STORE}/fhir"

# ---------- Helpers ----------
log()  { printf ">> %s\n" "$*"; }
fail() { echo "❌ $*" >&2; exit 1; }
pass() { echo "✅ $*"; }

need() { command -v "$1" >/dev/null 2>&1 || fail "Missing dependency: $1"; }

token() { gcloud auth print-access-token; }

ensure_topic() {
  local topic_fqn="projects/${PROJECT_ID}/topics/${1}"
  gcloud pubsub topics create "$topic_fqn" >/dev/null 2>&1 || true
  echo "$topic_fqn"
}

ensure_temp_sub() {
  local topic_fqn="$1"
  local sub="orders.created.peek.$RANDOM"
  gcloud pubsub subscriptions create "$sub" --topic="$topic_fqn" >/dev/null 2>&1 || true
  echo "$sub"
}

delete_sub() {
  gcloud pubsub subscriptions delete "$1" >/dev/null 2>&1 || true
}

ensure_patient() {
  # Try GET; if 404, create a minimal patient with fixed ID PATIENT_ID
  local got
  got="$(curl -sS -H "Authorization: Bearer $(token)" \
              -H "Accept: application/fhir+json" \
              "${FHIR_BASE}/Patient/${PATIENT_ID}" || true)"
  if [[ "${got}" == *'"resourceType":"OperationOutcome"'* && "${got}" == *'"code":"not-found"'* ]]; then
    log "Creating Patient/${PATIENT_ID}"
    curl -sS -X PUT \
      -H "Authorization: Bearer $(token)" \
      -H "Content-Type: application/fhir+json; charset=utf-8" \
      --data-binary @- "${FHIR_BASE}/Patient/${PATIENT_ID}" <<JSON >/dev/null
{
  "resourceType":"Patient",
  "id":"${PATIENT_ID}",
  "name":[{"family":"Test","given":["OrderFlow"]}],
  "gender":"female",
  "birthDate":"1980-01-01"
}
JSON
  else
    log "Patient/${PATIENT_ID} exists"
  fi
}

post_service_request() {
  # ECG order LOINC 6301-6
  jq -n --arg pid "$PATIENT_ID" '{
    resourceType:"ServiceRequest",
    status:"active",
    intent:"order",
    subject:{reference:("Patient/"+$pid)},
    authoredOn: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
    code:{coding:[{system:"http://loinc.org",code:"6301-6",display:"ECG study"}]}
  }' | curl -sS -X POST \
        -H "Authorization: Bearer $(token)" \
        -H "Content-Type: application/fhir+json; charset=utf-8" \
        --data-binary @- "${FHIR_BASE}/ServiceRequest" | jq -r '.id'
}

wait_for_envelope() {
  local sub="$1"
  local expect_id="$2"
  local timeout_sec="${3:-90}"
  local start_ts now_ts elapsed
  start_ts="$(date +%s)"

  while true; do
    # Pull up to 10 msgs; auto-ack so we don't re-read forever
    out="$(gcloud pubsub subscriptions pull "$sub" --auto-ack --limit=10 --format=json 2>/dev/null || true)"
    # Check for match by resource_id or by embedded resource id in the envelope's "resource" field
    if [[ -n "$out" && "$out" != "[]" ]]; then
      # Look for our ServiceRequest id in the envelope fields
      hit="$(echo "$out" | jq -r '
        .[].payload.data? // .[].message.data? // empty
        | @base64d? // .
        | try fromjson catch .
        | if type=="object" and .resource_id? == "'"$expect_id"'" then . else empty end
      ')"
      if [[ -n "$hit" ]]; then
        echo "$hit" | jq .
        return 0
      fi

      # Fallback: scan the stringified resource for the ID
      hit2="$(echo "$out" | jq -r '
        .[].payload.data? // .[].message.data? // empty
        | @base64d? // .
        | try fromjson catch .
        | select(type=="object" and (.resource? // "") | tostring | test("'"$expect_id"'"))
      ')"
      if [[ -n "$hit2" ]]; then
        echo "$hit2" | jq .
        return 0
      fi
    fi

    now_ts="$(date +%s)"; elapsed=$(( now_ts - start_ts ))
    if (( elapsed >= timeout_sec )); then
      echo "$out" | jq . >/dev/null 2>&1 || true
      return 1
    fi
    sleep 2
  done
}

# ---------- Main ----------
need gcloud; need jq; need curl

log "Project: ${PROJECT_ID} | Region: ${REGION} | Dataset: ${DATASET} | FHIR Store: ${FHIR_STORE}"
ensure_patient

topic_fqn="$(ensure_topic "$TOPIC")"
sub_id="$(ensure_temp_sub "$topic_fqn")"
trap 'delete_sub "$sub_id"' EXIT

log "Posting ServiceRequest (ECG order)…"
sid="$(post_service_request)"
[[ "$sid" != "null" && -n "$sid" ]] || fail "Failed to create ServiceRequest"

log "Waiting for envelope on ${TOPIC} (resource_id=${sid})…"
if wait_for_envelope "$sub_id" "$sid" 120; then
  pass "Orders route OK → ${TOPIC} (ServiceRequest ${sid})"
else
  fail "Timed out waiting for ${TOPIC} envelope for ServiceRequest ${sid}"
fi
