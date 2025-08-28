#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

ensure_patient
ensure_topic "notes.created"
ensure_sub "notes.created.peek" "notes.created"

log "Creating DocumentReference (note)"
NID="$(curl -sX POST "${FHIR_BASE}/DocumentReference" \
  -H "Authorization: Bearer $(token)" -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"DocumentReference","status":"current","subject":{"reference":"Patient/ca-100"},"type":{"text":"ED Note"},"date":"2025-01-08T20:25:00Z","content":[{"attachment":{"contentType":"text/plain","data":"SGVsbG8sIEVERiBub3RlIQ=="}}]}' | jq -r '.id')"
[[ "$NID" != "null" && -n "$NID" ]] || fail "failed to create DocumentReference"
wait_for_resource "notes.created.peek" "$NID" 60

pass "Notes route OK"
