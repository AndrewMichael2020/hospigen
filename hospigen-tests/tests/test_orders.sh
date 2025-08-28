#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

ensure_patient
ensure_topic "orders.created"
ensure_sub "orders.created.peek" "orders.created"

log "Creating ServiceRequest (ECG)"
SID="$(curl -sX POST "${FHIR_BASE}/ServiceRequest" \
  -H "Authorization: Bearer $(token)" -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"ServiceRequest","status":"active","intent":"order","subject":{"reference":"Patient/ca-100"},"authoredOn":"2025-01-08T18:58:00Z","code":{"coding":[{"system":"http://loinc.org","code":"6301-6","display":"ECG study"}]}}' | jq -r '.id')"
[[ "$SID" != "null" && -n "$SID" ]] || fail "failed to create ServiceRequest"
wait_for_resource "orders.created.peek" "$SID" 60

pass "Orders route OK"
