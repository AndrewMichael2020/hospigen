#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
set -x
"$HERE/test_observation_labs.sh"
"$HERE/test_rpm_observation.sh"
"$HERE/test_ed_triage.sh"
"$HERE/test_adt.sh"
"$HERE/test_orders.sh"
"$HERE/test_meds.sh"
"$HERE/test_procedures.sh"
"$HERE/test_notes.sh"
"$HERE/test_scheduling.sh"
set +x
echo "All tests passed."