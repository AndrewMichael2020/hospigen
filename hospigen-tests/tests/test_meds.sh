#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

ensure_patient
ensure_topic "meds.ordered"
ensure_topic "meds.administered"
ensure_sub "meds.ordered.peek" "meds.ordered"
ensure_sub "meds.administered.peek" "meds.administered"

log "Creating MedicationRequest (ordered)"
MRID="$(curl -sX POST "${FHIR_BASE}/MedicationRequest" \
  -H "Authorization: Bearer $(token)" -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"MedicationRequest","status":"active","intent":"order","subject":{"reference":"Patient/ca-100"},"authoredOn":"2025-01-08T19:55:00Z","medicationCodeableConcept":{"text":"Aspirin 81 mg PO daily"}}' | jq -r '.id')"
[[ "$MRID" != "null" && -n "$MRID" ]] || fail "failed to create MedicationRequest"
wait_for_resource "meds.ordered.peek" "$MRID" 60

log "Creating MedicationAdministration (administered)"
MAID="$(curl -sX POST "${FHIR_BASE}/MedicationAdministration" \
  -H "Authorization: Bearer $(token)" -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"MedicationAdministration","status":"completed","subject":{"reference":"Patient/ca-100"},"effectiveDateTime":"2025-01-08T20:05:00Z","medicationCodeableConcept":{"text":"Aspirin 81 mg"}}' | jq -r '.id')"
[[ "$MAID" != "null" && -n "$MAID" ]] || fail "failed to create MedicationAdministration"
wait_for_resource "meds.administered.peek" "$MAID" 60

pass "Meds ordered/administered routes OK"
