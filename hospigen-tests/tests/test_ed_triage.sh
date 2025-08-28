#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

ensure_patient
ensure_topic "ed.triage"
ensure_sub "ed.triage.peek" "ed.triage"

log "Creating ED triage Encounter (arrived)"
EID="$(curl -sX POST "${FHIR_BASE}/Encounter" \
  -H "Authorization: Bearer $(token)" -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Encounter","status":"arrived","class":{"system":"http://terminology.hl7.org/CodeSystem/v3-ActCode","code":"EMER","display":"emergency"},"subject":{"reference":"Patient/ca-100"},"period":{"start":"2025-01-08T18:55:00Z"},"reasonCode":[{"text":"Chest pain"}]}' | jq -r '.id')"
[[ "$EID" != "null" && -n "$EID" ]] || fail "failed to create ED encounter"

wait_for_resource "ed.triage.peek" "$EID" 60
pass "ED triage route OK"
