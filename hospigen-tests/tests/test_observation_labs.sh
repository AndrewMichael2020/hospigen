#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

ensure_patient

# prelim
log "Creating PRELIM Hgb (LOINC 718-7)"
OID_PRE="$(curl -sX POST "${FHIR_BASE}/Observation" \
  -H "Authorization: Bearer $(token)" -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Observation","status":"preliminary","code":{"coding":[{"system":"http://loinc.org","code":"718-7"}]},"subject":{"reference":"Patient/ca-100"},"effectiveDateTime":"2025-01-08T19:50:00Z","valueQuantity":{"value":141,"unit":"g/L"}}' | jq -r '.id')"
[[ "$OID_PRE" != "null" && -n "$OID_PRE" ]] || fail "failed to create prelim obs"

ensure_topic "results.prelim"
ensure_sub "results.prelim.peek" "results.prelim"
wait_for_resource "results.prelim.peek" "$OID_PRE" 60

# final
log "Creating FINAL Hgb (LOINC 718-7)"
OID_FIN="$(curl -sX POST "${FHIR_BASE}/Observation" \
  -H "Authorization: Bearer $(token)" -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Observation","status":"final","code":{"coding":[{"system":"http://loinc.org","code":"718-7"}]},"subject":{"reference":"Patient/ca-100"},"effectiveDateTime":"2025-01-08T19:55:00Z","valueQuantity":{"value":138,"unit":"g/L"}}' | jq -r '.id')"
[[ "$OID_FIN" != "null" && -n "$OID_FIN" ]] || fail "failed to create final obs"

RES_FINAL_TOPIC="${RESULTS_FINAL_TOPIC:-results.final.v1}"
ensure_topic "$RES_FINAL_TOPIC"
ensure_sub "${RES_FINAL_TOPIC}.peek" "$RES_FINAL_TOPIC"
wait_for_resource "${RES_FINAL_TOPIC}.peek" "$OID_FIN" 60

pass "Labs prelim+final routes OK"
