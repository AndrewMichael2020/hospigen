# Generate & ingest into BigQuery and create tables

This document describes the straightest, repeatable path we used to generate Synthea patients, ingest their per-patient NDJSON files into GCS, load them into a single-column BigQuery staging table, and materialize normalized tables.

Note: this file reflects the pipeline we executed in the repo workspace. The Cloud Function extractor was not deployed as part of this test (we did not finish implementing/ deploying it).

Straightforward pipeline (minimal steps, files listed)

1) Generate patients (Synthea fat JAR)
  - Script: `analytics/scripts/extract_vancouver_500.py`
   - Action: runs the Synthea JAR and writes per-patient JSON files to a local output directory (default `analytics/test_output` or `--out-dir`).
   - Flags to use for direct upload: `--upload --gcs-bucket <bucket> --gcs-prefix <prefix>`

2) Convert per-patient JSON -> NDJSON and upload (one NDJSON file per patient)
  - Script: `analytics/scripts/extract_vancouver_500.py` (same script; conversion and upload are internal when `--upload` is used)
   - Helpers inside script: `_convert_json_to_ndjson()` and `_upload_to_gcs()`
   - Behavior: creates a per-patient `<patient_####>.ndjson` and uploads it to `gs://<bucket>/<prefix>/`.

3) Optional local cleaning/validation (recommended)
   - Script: `analytics/scripts/validate_ndjson.py` (validates NDJSON lines)
   - Script: `analytics/scripts/clean_and_upload_ndjson.sh` (re-serializes lines and uploads)

4) Load NDJSON into BigQuery staging (explicit single JSON column)
   - Script: `analytics/bq/load_ndjson_from_gcs.sh`
   - Behavior: ensures the dataset/table exists and creates `raw_records_stg` with schema `raw:JSON` if missing, then runs `bq load` against a GCS glob (e.g. `gs://<bucket>/<prefix>/*.ndjson`) without `--autodetect`.
   - This results in one row per NDJSON resource line in `raw_records_stg.raw`.

5) Materialize normalized staging / flat tables via SQL (examples, not implemented as a single script)
   - Suggested folder for SQL transforms: `analytics/sql/` (not currently present; can be added)
   - Example transforms run manually via `bq query` or saved SQL files to create
     - `hospigen.synthea_raw.patients` (extract Patient resources)
     - `hospigen.synthea_raw.observations` (extract Observation resources)
     - `hospigen.synthea_raw.encounters` (extract Encounter resources)
   - We used ad-hoc bq SQL to create `hospigen.synthea_raw.patients` from `raw_records_smoke` during the smoke test.

Files and helpers present in repo
- Generator and upload
  - `analytics/scripts/extract_vancouver_500.py`
  - `analytics/generate_and_upload_bq.py` (older batch uploader that writes batches to ndjson files and uploads; kept for reference)
  - `analytics/run_generator.sh`

- Validation / cleaning
  - `analytics/scripts/validate_ndjson.py`
  - `analytics/scripts/clean_and_upload_ndjson.sh`
  - `analytics/scripts/ingest_batch.sh`

- BigQuery loaders
  - `analytics/bq/load_ndjson_from_gcs.sh` (creates `raw_records_stg` and loads into `raw:JSON`)
  - `analytics/bq/wrap_and_load_raw_json.sh` (testing helper)
  - `analytics/bq/split_and_load_ndjson.sh` (split large NDJSON prior to load)
  - `analytics/bq/load_from_gcs.sh` (legacy loader)

- Test outputs
  - `analytics/test_output_smoke/` (contains per-patient json/ndjson from the smoke run)

Practical notes and gotchas observed during testing
- Each patient produces many FHIR resource lines; the smoke run produced ~17k resource rows from 7 patients.
- Per-patient NDJSON files can be large (~10-20MB). Upload-and-delete (streaming) is recommended to keep local disk usage low.
- Loading with `--autodetect` caused schema fragmentation and multiple auto-created tables; explicit `raw:JSON` staging avoided those problems.
- For analysts, flattening JSON in BigQuery is practical but requires care with nested arrays and missing fields.

Removing already-uploaded patient files (idempotency)
- If a per-patient NDJSON was uploaded by mistake or you need to re-generate a patient, delete the object from GCS before re-uploading to avoid duplicate rows in staging.
- Example to delete a single patient file:

```bash
gsutil rm gs://<bucket>/<prefix>/patient_0001.ndjson
```

- Example to delete all files in a prefix (use with caution):

```bash
gsutil -m rm "gs://<bucket>/<prefix>/*.ndjson"
```

- Idempotency tips:
  - Use a consistent naming scheme (patient ID in filename) so you can safely remove and re-upload known objects.
  - Consider a per-run prefix (see `analytics/scripts/gcs_prefix.sh`) so re-runs target a new prefix and do not overlap previously materialized data.
  - If you must re-ingest into the same prefix, delete objects first and then run the upload.

Quick commands used in the smoke test
- Run small generation and upload:

```bash
python3 analytics/scripts/extract_vancouver_500.py --total 3 --batch-size 3 --seed 123 --out-dir analytics/test_output_smoke --upload --gcs-bucket synthea-raw-hospigen --gcs-prefix patients-smoke
```

- Load wrapped NDJSON into BQ staging (wrap step used for testing):

```bash
# wrap each NDJSON resource line into {"raw": <obj>} locally, then upload wrapped files to GCS
bq --project_id=<project> --location=<region> load --source_format=NEWLINE_DELIMITED_JSON <dataset>.raw_records_stg gs://<bucket>/<wrapped_prefix>/*.ndjson raw:JSON
```

- Create a patients table from the raw staging table (example):

```sql
CREATE OR REPLACE TABLE `hospigen.synthea_raw.patients` AS
SELECT
  JSON_EXTRACT_SCALAR(raw, '$.id') AS patient_id,
  JSON_EXTRACT_SCALAR(raw, '$.gender') AS gender,
  JSON_EXTRACT_SCALAR(raw, '$.birthDate') AS birth_date,
  JSON_EXTRACT_SCALAR(raw, '$.name[0].family') AS family_name,
  JSON_EXTRACT_SCALAR(raw, '$.address[0].city') AS city,
  raw AS raw
FROM `hospigen.synthea_raw.raw_records_stg`
WHERE JSON_EXTRACT_SCALAR(raw, '$.resourceType') = 'Patient';
```

Next improvements (recommendations)
- Implement streaming upload+delete in `analytics/scripts/extract_vancouver_500.py` to avoid local disk pressure when running 500 patients.
- Add SQL files under `analytics/sql/` to centralize the transforms for `patients`, `observations`, `encounters`, etc.
- Add a small CI job (smoke) that generates 1-3 patients and validates end-to-end ingestion into a temp dataset.

If you want, I will now update `analytics/scripts/extract_vancouver_500.py` to immediately upload and delete per-patient NDJSON files as they are created, then re-run a smoke test. Otherwise I will just leave this doc in place.
