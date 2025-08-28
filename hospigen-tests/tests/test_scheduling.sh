#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

ensure_patient
check_wiring
ensure_topic "scheduling.created"
ensure_sub "scheduling.created.peek" "scheduling.created"

log "Creating Appointment (booked)"
AID="$(curl -sX POST "${FHIR_BASE}/Appointment" \
  -H "Authorization: Bearer $(token)" -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Appointment","status":"booked","start":"2025-01-08T23:00:00Z","end":"2025-01-08T23:30:00Z","participant":[{"actor":{"reference":"Patient/ca-100"},"status":"accepted"}]}' | jq -r '.id')"
[[ "$AID" != "null" && -n "$AID" ]] || fail "failed to create Appointment"
wait_for_resource "scheduling.created.peek" "$AID" 60

pass "Scheduling route OK"
