#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

ensure_patient
ensure_topic "adt.admit"; ensure_topic "adt.transfer"; ensure_topic "adt.discharge"
ensure_sub "adt.admit.peek" "adt.admit"
ensure_sub "adt.transfer.peek" "adt.transfer"
ensure_sub "adt.discharge.peek" "adt.discharge"

# Admit
log "Creating IP admit Encounter (in-progress)"
EID="$(curl -sX POST "${FHIR_BASE}/Encounter" \
  -H "Authorization: Bearer $(token)" -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Encounter","status":"in-progress","class":{"system":"http://terminology.hl7.org/CodeSystem/v3-ActCode","code":"IMP","display":"inpatient encounter"},"subject":{"reference":"Patient/ca-100"},"period":{"start":"2025-01-08T19:40:00Z"}}' | jq -r '.id')"
[[ "$EID" != "null" && -n "$EID" ]] || fail "failed to create admit encounter"
wait_for_resource "adt.admit.peek" "$EID" 60

# Transfer (update while in-progress)
log "Patching Encounter to indicate unit transfer"
TOK="$(token)"
curl -sX PATCH "${FHIR_BASE}/Encounter/${EID}" \
  -H "Authorization: Bearer ${TOK}" \
  -H "Content-Type: application/json-patch+json" \
  -d '[{"op":"add","path":"/serviceType","value":{"text":"Transfer to ICU"}}]' >/dev/null
wait_for_resource "adt.transfer.peek" "$EID" 60

# Discharge
log "Finishing Encounter (discharge)"
curl -sX PATCH "${FHIR_BASE}/Encounter/${EID}" \
  -H "Authorization: Bearer ${TOK}" \
  -H "Content-Type: application/json-patch+json" \
  -d '[{"op":"replace","path":"/status","value":"finished"},{"op":"add","path":"/period/end","value":"2025-01-08T21:10:00Z"}]' >/dev/null
wait_for_resource "adt.discharge.peek" "$EID" 60

pass "ADT admit/transfer/discharge routes OK"
