# Hospigen Bridge E2E Test Suite (bash)

This is a small, idempotent test harness to exercise each routing path via the FHIR store and verify
that the expected Pub/Sub message lands in the corresponding topic (using a `*.peek` subscription).

## Prereqs
- You are in Cloud Shell or have `gcloud`, `jq`, and `curl` installed.
- Your `.env` in the repo is filled and sourced (`source .env`). At minimum:
  - `PROJECT_ID=hospigen`
  - `REGION=northamerica-northeast1`
  - `DATASET_ID=hospitalgen-ds`
  - `STORE_ID=hospitalgen-fhir`
  - `RESULTS_FINAL_TOPIC=results.final.v1` (or whatever you configured)

## Quick start
```bash
cd hospigen  # your repo root
# copy these files in (or download the archive and extract into your repo)
chmod +x tests/*.sh
source .env
tests/test_observation_labs.sh            # prelim + final labs
tests/test_rpm_observation.sh             # vital signs to rpm.observation.created
tests/test_ed_triage.sh                   # ED triage (Encounter arrived)
tests/test_adt.sh                         # admit -> transfer -> discharge
tests/test_orders.sh                      # ServiceRequest -> orders.created
tests/test_meds.sh                        # MedicationRequest, MedicationAdministration
tests/test_procedures.sh                  # Procedure completed
tests/test_notes.sh                       # DocumentReference (note)
tests/test_scheduling.sh                  # Appointment booked
# or run all (serially):
tests/run_all.sh
```

Each script prints PASS/FAIL and exits non‑zero on failure, so they can be used in CI.

## Notes
- The scripts will upsert `Patient/ca-100` as needed.
- "Peek" subscriptions are created once and re-used (e.g. `results.final.v1.peek`).

