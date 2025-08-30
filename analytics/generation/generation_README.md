## Analytics / Generation — pipeline README

This folder contains the small, opinionated generation + ingestion pipeline used to
produce Synthea patients, upload one NDJSON file per patient to GCS, wrap those
files for BigQuery, and materialize a `patients` table in BigQuery.

Files
- `step_1_generate_data.py` — generate Synthea patients (per-patient JSON -> NDJSON), attach a generated timestamp (resource.meta.generated), upload per-patient NDJSON to GCS, optionally delete local JSON files.
- `step_2_wrap_and_load.sh` — download NDJSON file(s) from GCS, wrap each resource line as `{ "raw": <resource> }`, upload wrapped file to a wrapped prefix and load that single wrapped file into the BigQuery staging table `synthea_raw.raw_records_stg` (append mode).
- `step_3_materialize_tables.sh` — ensure dataset + staging table exist, call the wrapper per-file (so each patient file is handled once), then MERGE (upsert) from staging into `patients` with `generated_ts` and `ingestion_ts` columns.
- `full_generation_pipeline.sh` — simple orchestrator that runs the three steps in order for a timestamped prefix.

Goals and guarantees
- One file per patient is uploaded to GCS (NDJSON). This keeps files small and makes retrying a single patient cheap.
- Wrapping converts resource objects into a single JSON column row: `{ "raw": <resource> }` so BigQuery's `JSON` type can be used as a raw column.
- The materialize step performs a MERGE (upsert) on `patient_id` and writes `ingestion_ts = CURRENT_TIMESTAMP()` and uses `generated_ts` when present (resource.meta.generated). This makes ingestion incremental and safe to re-run.

Quick start (dry-run)
1. From the repo root, run a dry-run to see what would be executed:

```bash
BUCKET=synthea-raw-hospigen TOTAL=2 BATCH_SIZE=1 \
  bash analytics/generation/full_generation_pipeline.sh
```

Quick start (real run)
1. Run a small smoke generation end-to-end (this actually uploads and loads into BigQuery):

```bash
BUCKET=synthea-raw-hospigen TOTAL=10 BATCH_SIZE=5 \
  bash analytics/generation/full_generation_pipeline.sh
```

Notes on the arguments you can set
- BUCKET — GCS bucket to upload to. Default is `synthea-raw-hospigen` in the scripts.
- TOTAL — total number of patients to generate (passed to Synthea generator).
- BATCH_SIZE — Synthea runs are performed in batches; generator supports running multiple batches.
- PROJECT — BigQuery project (default `hospigen`).
- LOCATION — BigQuery location (default `northamerica-northeast1`).

Per-step details and examples
- Step 1 — generation
  - Command: `python3 analytics/generation/step_1_generate_data.py --total 50 --batch-size 50 --upload --gcs-bucket $BUCKET --gcs-prefix $PREFIX --delete-local`
  - Behavior: produces per-patient NDJSON files named `patient_0001.ndjson` etc and uploads them to `gs://$BUCKET/$PREFIX/`.
  - Adds `meta.generated` to each resource (ISO 8601 UTC) so `generated_ts` is available when materializing.

- Step 2 — wrap + load
  - Command: `bash analytics/generation/step_2_wrap_and_load.sh --bucket $BUCKET --prefix $PREFIX --project $PROJECT`
  - Behavior: downloads the NDJSON files, wraps them as `{ "raw": <resource> }` (one line per resource), uploads wrapped files under `.../<prefix>_wrapped/` and runs a `bq load` to append into `${PROJECT}:synthea_raw.raw_records_stg`.
  - The wrapper supports `--file <filename>` to process a single file; the stage script uses that to avoid duplicate source rows.

- Step 3 — materialize
  - Command: `bash analytics/generation/step_3_materialize_tables.sh --bucket $BUCKET --prefix $PREFIX --project $PROJECT`
  - Behavior: ensures dataset & staging table exist, invokes Step 2 for each per-patient file (so wrapped files are created and loaded individually), then creates/replaces the `patients` table schema and MERGEs (upserts) new/updated patients. `ingestion_ts` is set to CURRENT_TIMESTAMP() during the MERGE.

Verification (simple queries)
- Check staging table contents (one example row):

```bash
gsutil cat gs://$BUCKET/$PREFIX/patient_0001.ndjson | head -n1
```

- Find a couple of patient IDs from the materialized `patients` table:

```bash
bq --format=prettyjson query --nouse_legacy_sql \
  'SELECT patient_id, generated_ts, ingestion_ts FROM `hospigen.synthea_raw.patients` ORDER BY ingestion_ts DESC LIMIT 5'
```

Design notes, idempotency and re-runs
- Staging is append-oriented: wrapped files are uploaded under wrapped prefixes. The wrapper checks if a wrapped file already exists and will skip re-uploading/re-loading it.
- Materialize uses MERGE with GROUP BY + ANY_VALUE on the staging source to ensure the MERGE sees at most one source row per patient, avoiding multi-row merge errors.
- If you want to re-run ingest for a prefix, the safe pattern is:
  1. Re-upload the per-patient NDJSON to a fresh prefix (or use same prefix but remove wrapped objects), and
  2. Run `step_3_materialize_tables.sh` against the new prefix.

Timestamps and provenance
- `generated_ts` — recorded at generation time and written into the resource as `resource.meta.generated` by the generator.
- `ingestion_ts` — recorded in the MERGE as CURRENT_TIMESTAMP() for the row when it is merged into the `patients` table.

Troubleshooting & tips
- Permissions: ensure the active gcloud account has GCS write and BigQuery create/load permissions in the target project.
- BigQuery dataset creation: scripts use `bq mk --dataset`. If dataset creation fails, verify billing/project access.
- Large runs: prefer larger batch sizes to reduce total Synthea startup overhead, but keep in mind memory and disk constraints; the pipeline deletes local JSON files after upload when `--delete-local` is used.
- Cleanup: wrapped files are preserved for auditing. If you want to delete wrapped files after load, add a `gsutil rm` step in the wrapper (optional).

Where to go from here
- Run `full_generation_pipeline.sh` with a small smoke run first to validate credentials and quotas.
- When comfortable, increase `TOTAL` to the desired count and use `--delete-local` to avoid disk pressure.

If you'd like, I can:
- update the top-level doc or root `analytics/full_staging_pipeline.sh` to point to this new generation folder, or
- run a smoke end-to-end run now and return sample patient IDs.
