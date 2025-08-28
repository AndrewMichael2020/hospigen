#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

ensure_patient
ensure_topic "procedures.performed"
ensure_sub "procedures.performed.peek" "procedures.performed"

log "Creating Procedure (completed)"
PID="$(curl -sX POST "${FHIR_BASE}/Procedure" \
  -H "Authorization: Bearer $(token)" -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Procedure","status":"completed","subject":{"reference":"Patient/ca-100"},"performedDateTime":"2025-01-08T20:20:00Z","code":{"text":"Chest X-ray"}}' | jq -r '.id')"
[[ "$PID" != "null" && -n "$PID" ]] || fail "failed to create Procedure"
wait_for_resource "procedures.performed.peek" "$PID" 60

pass "Procedures route OK"
