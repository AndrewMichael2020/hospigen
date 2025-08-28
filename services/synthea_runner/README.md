Synthea Runner (Cloud Run)

- Cloud Run Job/Service to generate Synthea data and upload transaction bundles to a Google Cloud Healthcare FHIR store.

Prereqs
- Repo `.env` with PROJECT_ID, REGION, DATASET/STORE or STORE_ID_PATH (use scripts/fill_env.sh)
- ca/src/main/resources with Canada modules and geography (use scripts/synthea/fetch_ca_resources_only.sh)

Quick start (Job)
- bash services/synthea_runner/deploy_job.sh

Notes
- Image builds the JRE + downloads the Synthea JAR and copies Canada resources.
- Rate limits via MAX_QPS, retries transient errors.
- For ad-hoc runs as a Service, set MODE=service and hit POST /generate.

Canada geography notes
- This runner points Synthea at a geography directory bundled in the image and sets `generate.geography.international=true` and `generate.geography.country_code=CA`.
- The canonical Canada CSVs are shipped by Synthea under:
	- `synthea/src/main/resources/geography/demographics_ca.csv`
	- `synthea/src/main/resources/geography/zipcodes_ca.csv`
	- `synthea/src/main/resources/geography/timezones_ca.csv`
	These contain, for example, `Surrey, British Columbia` in demographics and zipcodes.
- In this repo we also keep a copy under `ca/src/main/resources/geography/` which is what the Dockerfile copies into the image at `/app/synthea/resources/geography/`.
- Province and city arguments must exactly match the strings in `demographics_ca.csv` (e.g., `British Columbia` and `Surrey`).
- Canada-specific limitations: no Veterans data, no ZDoh, and no FIPS/FIP codes for Canada (they are not mapped for CA). The runner does not attempt to generate or map these.
