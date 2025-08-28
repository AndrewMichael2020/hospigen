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
