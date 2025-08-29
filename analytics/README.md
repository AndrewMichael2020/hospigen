# Analytics pipeline (BigQuery)

This folder contains a lightweight, FHIR-free pipeline to load Synthea CSV exports into BigQuery for fast analytics, as well as tools to generate synthetic patient data locally.

What it does:
- **Patient Generation**: Generate synthetic patients for Greater Vancouver Area as JSON files
- Stages Synthea CSVs to GCS.
- Loads into BigQuery staging tables using autodetect.
- Materializes partitioned/clustered analytical tables via CTAS.
- Creates helpful views (ED, Primary Care) and an example feature table.

You can run end-to-end with one script if you already have local CSVs from Synthea.

## Quick start

### Generate Vancouver Patients (NEW)

To generate 1,000 synthetic patients for the Greater Vancouver Area as JSON files:

```bash
cd analytics
./run_generator.sh
```

This will:
- Download the Synthea JAR if needed
- Clone the Synthea repository if needed  
- Generate 1,000 patients across Vancouver, Burnaby, Surrey, and Richmond
- Output JSON files to `analytics/output/`
- Create a generation summary in `analytics/output/generation_summary.json`

Prerequisites: Java 11+, Git, Python 3

### BigQuery Pipeline

Prereqs: gcloud, bq, gsutil installed and authenticated; `.env` containing PROJECT_ID and REGION (e.g., northamerica-northeast1).

1) Upload local Synthea CSV folder(s) to a bucket and load into BigQuery:

```bash
./analytics/run_pipeline_from_local_csv.sh \
  --dataset hc_demo \
  --bucket gs://synthea-raw-$PROJECT_ID \
  --csv-root /path/to/synthea/output/csv
```

2) Or if your CSVs are already in GCS under run_* folders:

```bash
./analytics/bq/load_from_gcs.sh \
  --dataset hc_demo \
  --gcs "gs://synthea-raw-$PROJECT_ID/run_*"
```

Outputs:
- Tables: patients, encounters, observations, ... (partitioned where relevant)
- Views: v_encounters_ed, v_encounters_pc
- Example features: features_ed_7d

Note: This pipeline doesn’t touch the Cloud Run FHIR components.
