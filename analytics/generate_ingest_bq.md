# Generate and ingest into BigQuery (pipeline summary)

This document describes the pipeline we implemented to generate synthetic patients with Synthea, ingest the generated JSON into Google Cloud Storage (GCS), and load them into BigQuery for downstream transformation.

Overview
- Goal: reliably move Synthea-generated FHIR bundles (JSON) from Synthea -> GCS -> BigQuery while preserving a raw/landing layer and creating flattened tables for analysis.
- Key constraints: no FHIR store; operate on generated files in GCS; batches ~350 MB each; robust against schema heterogeneity across resource types.

High-level pipeline
1. Generate patients with Synthea (fat JAR) in batches.
2. For each generated patient JSON bundle, convert to NDJSON (one resource per line). We generate and upload one NDJSON file per patient (no large batch bundle files).
3. Upload per-patient NDJSON files to GCS under a stable prefix (e.g., `gs://<bucket>/patients/`).
4. Load NDJSON into BigQuery into a single-column staging table `raw_records_stg` (raw:JSON) to avoid schema autodetection issues.
5. Transform `raw_records_stg` into normalized staging/flat tables (patients, observations, encounters, claims, etc.) via SQL.

Why a single JSON column staging table
- Synthea bundles contain many resource types with widely varying nested fields; BigQuery's autodetect produces different inferred schemas for different files and causes inconsistent tables and load failures.
- Loading every NDJSON line into a single JSON column (`raw`) gives a stable landing zone that can be parsed and flattened deterministically with SQL.

Implementation notes (what we added)
- `analytics/extract_vancouver_500.py`
  - Generates Synthea patients in batches (configurable `--total` / `--batch-size`).
  - New flags: `--upload`, `--gcs-bucket`, `--gcs-prefix` to convert generated patient JSONs to NDJSON and upload them to GCS.
  - Added conversion `_convert_json_to_ndjson()` and upload helper that uses `gsutil cp`.

- Cloud Function `cloud_functions/extract_resources/main.py` (deployed separately)
  - Trigger: GCS object create at `synthea_batches/`.
  - Streams bundle and writes per-resource NDJSON to `processed_resources/` prefix.
  - Implemented streaming download to avoid OOM and increased memory for large bundles.

- `analytics/bq/load_ndjson_from_gcs.sh`
  - Loading helper updated to *disable* `--autodetect` and instead ensure a single-column table `raw_records_stg` with schema `raw:JSON`. Loads NDJSON into that column directly.

- Helpers
  - `analytics/scripts/clean_and_upload_ndjson.sh` — reserializes and cleans NDJSON lines (UTF-8 safe) before upload.
  - `analytics/bq/wrap_and_load_raw_json.sh` — for testing: wraps each NDJSON line into `{"raw": <obj>}` so BigQuery can ingest as JSON column.
  - `analytics/bq/split_and_load_ndjson.sh` — splits large NDJSON into parts to isolate bad records during debugging.

Smoke test results
- Ran a smoke generation of several patients locally and uploaded per-patient NDJSON to `gs://synthea-raw-hospigen/patients-smoke/`.
- Wrapped each NDJSON line and loaded into `hospigen.synthea_raw.raw_records_smoke` (raw:JSON).
- `raw_records_smoke` contains one row per resource (not one row per patient). Example: 7 patients generated produced 17,338 resource rows.
- Created `hospigen.synthea_raw.patients` by extracting Patient resource rows from the `raw` column; verified 7 patient rows.

Recommended ingestion pattern
- Produce many small NDJSON files (one per patient) rather than a few large bundle files. Advantages:
  - Easier retries and isolation of bad records.
  - More robust loads into BigQuery.
  - Smaller memory usage in Cloud Functions and local pipelines.

Loading into BigQuery: two safe options
1. Preferred: load NDJSON into a single JSON column staging table (what we implemented):
   - stable, avoids autodetect pitfalls, SQL-friendly to flatten nested fields.
2. Alternate: load per-resource NDJSON into typed staging tables with pre-defined schemas (requires mapping FHIR resources to table schemas and stable JSON shapes).

Next steps and follow-ups
- Update `analytics/extract_vancouver_500.py` to stream-and-delete per-patient NDJSON files during upload to minimize disk usage (recommended before running 500 patients).
- Implement SQL transforms to create normalized staging tables (observations, encounters, medications, claims) from `raw_records_stg` and add views for analysts.
- Add automated smoke test and CI that runs small patient generation, uploads, loads to BigQuery in a temp dataset, and validates counts.
- Consider granting a service account permission for bq job creation so ingestion can be fully automated server-side (Cloud Function -> load job) rather than using gsutil from local runner.

How to run the full generator safely (suggested)
1. Set `gcloud` auth and default project.
2. Ensure JAR exists or run with `--build-if-missing`.
3. Run the generator with upload and streaming-delete enabled (script can be updated to do streaming-delete). Example:

```bash
python3 analytics/extract_vancouver_500.py --total 500 --batch-size 50 --upload --gcs-bucket synthea-raw-hospigen --gcs-prefix patients
```

4. Use `analytics/bq/load_ndjson_from_gcs.sh --dataset synthea_raw --gcs 'gs://synthea-raw-hospigen/patients/*.ndjson'` to load into `raw_records_stg`.
5. Run SQL transforms to create normalized tables.

Contact
- For questions about field mappings or adding production monitoring, open an issue in the repo or ping the analytics team.
