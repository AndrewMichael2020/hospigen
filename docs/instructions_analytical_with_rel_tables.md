# Instructions: Analytical Data Pipeline with Relational Tables

**Scenario:**  
We currently generate synthetic patients with Synthea inside Codespaces. Originally, the plan was to deploy to Cloud Run and populate a FHIR store.  
However, we realized FHIR is not needed for our use case. The real requirement is **fast analytics** (ML jobs, ED utilization, labs, primary care, etc.) on up to **5.5 million synthetic patients**.

**Request:**  
Keep the FHIR Store and workflow, and Provide a concise plan to replace FHIR with a relational analytics pipeline, focusing on BigQuery tables (ED, labs, primary care, etc.), while generating Synthea data locally and uploading to GCP for cost‑effective storage and analysis.


## Best Option: BigQuery with GCS Landing (No FHIR)

### Overview
- Generate Synthea data as CSV locally.
- Upload to Google Cloud Storage (GCS) in Canada region northwest1.
- Load into partitioned + clustered BigQuery tables for fast analytics.
- Create specialized views for Emergency Department (ED), Primary Care, and Labs.
- Scale from 100k to 5.5M patients using sharded runs.

---


Tables: 
Now (keep these):

patients, organizations, providers

encounters (ED/PC via ENCOUNTERCLASS/TYPE)

conditions, procedures

observations (+ observations_lab)

medications, immunizations, allergies

careplans, claims, imaging_studies, devices

Views: v_encounters_ed, v_encounters_pc

Feature tables (e.g., features_ed_7d)

Later (add if you want a richer “system” view):

Dims: dim_patient, dim_provider, dim_org_facility, dim_date

Facts (derived):

fact_ed_events (arrival, triage, bed, disposition)

fact_orders (labs/diagnostics ordered)

fact_med_admin (administrations from meds + encounters)

fact_vitals (from observations: HR, BP, SpO₂)

fact_referrals (ED → PC handoffs)

Concept maps: map_loinc, map_snomed, map_icd (for grouping/roll-ups)

Rollups/views: v_patient_timeline, v_ed_return_7d, v_lab_panels

Start with the Now set; add the Later tables only if you need the extra fidelity or specific KPIs. Got it.

----

### Step 1: Configure Synthea for CSV
Edit `synthea.properties`:
```properties
exporter.csv.export = true
exporter.fhir.export = false
exporter.baseDirectory = ./output
exporter.csv.append_mode = false
```

Run in shards (100k per run, scalable):
```bash
./run_synthea -p 100000 -s 12345 -e 2026-12-31
```

---

### Step 2: Stage Data to Cloud Storage
Use Montreal region `northamerica-northeast1` (adjust if needed):
```bash
gsutil mb -l northamerica-northeast1 gs://synthea-raw-$PROJECT_ID
gsutil -m cp -r ./output/csv/run_*/ gs://synthea-raw-$PROJECT_ID/
```

---

### Step 3: Create BigQuery Dataset
```bash
bq --location=northamerica-northeast1 mk --dataset hc_demo
```

---

### Step 4: Load via staging then CTAS (safer)
To avoid header name mismatches and get proper partitioning, load into staging with autodetect, then create final tables with CTAS. Use the helper script:
```bash
./analytics/bq/load_from_gcs.sh \
  --dataset hc_demo \
  --gcs "gs://synthea-raw-$PROJECT_ID/run_*"
```

This script also creates a labs-only table and the ED/PC views.

---

### Step 5: Create Views
Emergency Department:
```sql
CREATE OR REPLACE VIEW hc_demo.v_encounters_ed AS
SELECT *
FROM hc_demo.encounters
WHERE LOWER(ENCOUNTERCLASS) = 'emergency' OR LOWER(TYPE) LIKE '%emergency%';
```

Primary Care:
```sql
CREATE OR REPLACE VIEW hc_demo.v_encounters_pc AS
SELECT *
FROM hc_demo.encounters
WHERE LOWER(TYPE) LIKE '%primary%' OR LOWER(TYPE) LIKE '%clinic%';
```

---

### Step 6: Keys and Joins
- Patients join: `patients.PATIENT` ↔ `encounters.PATIENT`
- Encounters join: `encounters.ENCOUNTER` ↔ `observations.ENCOUNTER`

Optional surrogate key:
```sql
CREATE OR REPLACE TABLE hc_demo.dim_patient AS
SELECT
  FARM_FINGERPRINT(PATIENT) AS patient_sk,
  * EXCEPT(PATIENT)
FROM hc_demo.patients;
```

---

### Step 7: ML Feature Table Example
```sql
CREATE OR REPLACE TABLE hc_demo.features_ed_7d
PARTITION BY _PARTITIONDATE
AS
SELECT
  e.PATIENT,
  COUNTIF(o.CATEGORY='laboratory' AND o.DATE BETWEEN TIMESTAMP_SUB(e.START, INTERVAL 7 DAY) AND e.START) AS labs_last_7d,
  COUNTIF(proc.DATE BETWEEN TIMESTAMP_SUB(e.START, INTERVAL 30 DAY) AND e.START) AS procedures_last_30d,
  ANY_VALUE(p.GENDER) AS gender,
  ANY_VALUE(p.BIRTHDATE) AS birthdate,
  e.START AS ed_start
FROM hc_demo.v_encounters_ed e
LEFT JOIN hc_demo.observations o ON o.PATIENT = e.PATIENT
LEFT JOIN hc_demo.procedures proc ON proc.PATIENT = e.PATIENT
LEFT JOIN hc_demo.patients p ON p.PATIENT = e.PATIENT
GROUP BY e.PATIENT, e.START;
```

---

### Step 8: Cost Management
- GCS Standard for raw; set lifecycle to Nearline after 30 days.
- Partition all large tables on dates.
- Cluster on patient and code fields.
- Shard Synthea runs with different seeds until 5.5M patients are reached.

---

### Summary
- **No FHIR needed.**
- **BigQuery** + **partitioned tables** + **views for ED, labs, primary care**.
- **Scale to millions of patients** with cheap storage and fast SQL for ML analytics.
