#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

ensure_patient
check_wiring

RPM_TOPIC="${RPM_OBS_CREATED_TOPIC:-rpm.observation.created}"
ensure_topic "$RPM_TOPIC"
ensure_sub "${RPM_TOPIC}.peek" "$RPM_TOPIC"

log "Creating SpO2 vital (LOINC 59408-5)"
OID="$(curl -sX POST "${FHIR_BASE}/Observation" \
  -H "Authorization: Bearer $(token)" -H "Content-Type: application/fhir+json" \
  -d '{"resourceType":"Observation","status":"final","category":[{"coding":[{"system":"http://terminology.hl7.org/CodeSystem/observation-category","code":"vital-signs"}]}],"code":{"coding":[{"system":"http://loinc.org","code":"59408-5","display":"Oxygen saturation in Arterial blood by Pulse oximetry"}]},"subject":{"reference":"Patient/ca-100"},"effectiveDateTime":"2025-01-08T20:35:00Z","valueQuantity":{"value":97,"unit":"%"} }' | jq -r '.id')"
[[ "$OID" != "null" && -n "$OID" ]] || fail "failed to create rpm obs"

wait_for_resource "${RPM_TOPIC}.peek" "$OID" 60
pass "RPM observation route OK"
