## Hospigen — Canadian healthcare synthetic data & analytics

![Synthetic Data](https://img.shields.io/badge/data-synthetic%20healthcare-0f766e)
![FHIR](https://img.shields.io/badge/standard-FHIR-E34F26)
![Google Cloud](https://img.shields.io/badge/platform-Google%20Cloud-4285F4?logo=googlecloud&logoColor=white)
![BigQuery](https://img.shields.io/badge/analytics-BigQuery-669DF6?logo=googlebigquery&logoColor=white)
![FastAPI](https://img.shields.io/badge/API-FastAPI-009688?logo=fastapi&logoColor=white)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

This repository contains a small, opinionated toolset for generating synthetic Canadian healthcare data (via Synthea), publishing it into a Google Cloud FHIR Store, and turning those clinical events into analytics-ready BigQuery tables for dashboards and ML.

Two primary entry points:

- Analytics (generation): see `analytics/generation/README.md` — the generation pipeline that runs Synthea, uploads per-patient NDJSON to GCS, loads into a BigQuery staging table, and materializes analytic tables (e.g., patients) for dashboards and machine learning.
- Services (FHIR bridge): see `services/bridge/bridge_README.md` — a FastAPI bridge that listens to FHIR Store change notifications, fetches full FHIR resources, wraps them as business events, and publishes to Pub/Sub.

Scope
- In `/services` we run Synthea and operate the Bridge to populate a Google Cloud FHIR Store and emit downstream event streams.
- In `/analytics/generation` we build the analytics pipeline that ingests GCS / FHIR events into BigQuery for reporting, dashboards, and ML experiments.

Next steps / roadmap

- Create a more "living hospital system" where events naturally occur as time passes (continuous time simulation).
- Modify Synthea modules and orchestration so protocol-driven scenarios can be played (e.g., outbreak, surge, clinical pathways).
- Add real-time (RT) pipelines and streaming metrics so dashboards can surface signals like "Average real-time heart rate in the hospital" (haha).
- Implement remote patient monitoring (RPM) scenarios that combine RT or batch ingestion with ML / Generative AI analytics on top for anomaly detection, risk scoring, or decision support.

Context
- This work is oriented to Canadian healthcare settings and uses Canadian defaults and assumptions where applicable.

See also
- `services/bridge/bridge_README.md`
- `analytics/generation/README.md`
