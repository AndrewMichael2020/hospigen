# Synthea for Canada (Hospigen)

This doc shows how to generate synthetic Canadian patient data with Synthea and (optionally) load it into BigQuery or a FHIR store later.

## Prereqs
- Java 11+
- curl, git, rsync, jq
- gcloud auth login (and access to your GCP project)
- `.env` configured (see existing scripts). Required for upload: `PROJECT_ID, REGION, DATASET, FHIR_STORE`.

## Get the code and Canada data (lightweight)
We keep it simple and repo-local:

```bash
# 1) Clone Synthea into ./synthea
git clone https://github.com/synthetichealth/synthea synthea

# 2) Fetch only the Canada resources into ./ca/src/main/resources
bash scripts/synthea/fetch_ca_resources_only.sh

# 3) Copy Canada resources into the Synthea tree (official docs pattern)
bash scripts/synthea/prepare_canada_in_synthea.sh
```

At this point Synthea has Canada geography/payers/providers under `synthea/src/main/resources/`.

## Generate data (when ready)
Run Synthea targeting British Columbia (Lower Mainland examples):

```bash
# From the Synthea repo runner (docs-style)
cd synthea
./run_synthea -p 25 "British Columbia" Vancouver

# Other Lower Mainland cities:
# ./run_synthea -p 25 "British Columbia" Burnaby
# ./run_synthea -p 25 "British Columbia" Surrey
# ./run_synthea -p 25 "British Columbia" Richmond

# Province-wide (omit city):
# ./run_synthea -p 100 "British Columbia"
```

Bundles will appear in `synthea/output/fhir/` as transaction bundles.

## Load to BigQuery (no FHIR yet)
If you prefer to analyze in BigQuery first, generate with CSV output (add the `--csv` flag when running the generator). Then load the CSVs into a BigQuery dataset:

1) Generate with CSVs by running the JAR path with `--csv` (alternative to run_synthea):
   
	```bash
	# Using the convenience runner we provide (optional)
	bash scripts/synthea/run_synthea_canada.sh --count 100 --province BC --city Vancouver --csv
	```

2) Load to BigQuery dataset using the loader script (autodetect schema, skip headers):

	```bash
	bash scripts/synthea/load_csv_to_bigquery.sh --dataset synthea_ca --location US
	```

Tables will be created per CSV file name in your dataset.

## Upload to FHIR (optional)
Ensure `.env` has `PROJECT_ID, REGION, DATASET, FHIR_STORE`, then:

```bash
bash scripts/synthea/upload_synthea_to_fhir.sh
```

This posts each bundle to the FHIR base using a transaction.

## Notes
- You can tweak `synthea/config/synthea-canada.properties` and re-run (used by the JAR runner script).
- For other provinces/cities, use the province name and city string (e.g., "Ontario" Toronto, "Quebec" Montreal).
- For performance, increase `--count` and ensure sufficient memory for Java.
 - If you’re deferring FHIR ingestion, stick to CSV + BigQuery for validation, and plan a later transform to your FHIR store.
