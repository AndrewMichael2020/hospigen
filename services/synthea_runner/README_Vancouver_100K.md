# Vancouver 100K Patient Generation Guide

This guide shows how to generate 100,000 synthetic patients for the Greater Vancouver Area using the Synthea runner service.

## Overview

Due to Canadian geography data compatibility issues with Synthea, we use a **hybrid approach** that:
- Uses Seattle, Washington geography (Pacific Northwest, similar demographics)
- Generates patients with characteristics similar to Greater Vancouver Area residents
- Outputs both CSV and FHIR formats for analysis

## Quick Start

1. **Set up environment**:
   ```bash
   # Copy and configure .env
   cp .env_example .env
   # Edit .env with your GCP project details
   ```

2. **Deploy and run 100K generation**:
   ```bash
   cd services/synthea_runner
   ./deploy_vancouver_100k.sh
   ```

3. **Monitor execution**:
   ```bash
   gcloud run jobs executions list --job=synthea-runner-vancouver-100k --region=$REGION --project=$PROJECT_ID
   gcloud logs read --project=$PROJECT_ID
   ```

## Output Format

The generation produces **CSV files** with standard Synthea format:

### Core Files
- `patients.csv` - Patient demographics, addresses, demographics
- `encounters.csv` - Healthcare encounters (ED visits, appointments, admissions)
- `conditions.csv` - Diagnosed conditions and diseases
- `procedures.csv` - Medical procedures performed
- `medications.csv` - Prescribed medications
- `observations.csv` - Lab results, vital signs, assessments

### Additional Files
- `allergies.csv` - Patient allergies
- `careplans.csv` - Care plans and goals
- `claims.csv` - Insurance claims
- `immunizations.csv` - Vaccination records
- `organizations.csv` - Healthcare organizations
- `providers.csv` - Healthcare providers
- `payers.csv` - Insurance payers

## Key Features

### Patient Demographics
- **Population**: 100,000 patients
- **Geography**: Seattle area (representing Greater Vancouver demographics)
- **Age Distribution**: Realistic age distribution across all age groups
- **Gender**: Balanced male/female distribution
- **Diversity**: Includes diverse ethnic and socioeconomic backgrounds

### Clinical Data
- **Complete Medical Histories**: Birth to death or present day
- **Realistic Disease Progression**: Evidence-based disease models
- **Healthcare Utilization**: Realistic patterns of healthcare usage
- **Medications**: Evidence-based prescribing patterns
- **Lab Results**: Realistic lab values and trends

### Quality Assurance
- **Reproducible**: Uses seed value for consistent results
- **FHIR Compliant**: Outputs valid FHIR R4 resources
- **Realistic Timelines**: Proper temporal relationships between events
- **Clinical Accuracy**: Based on real-world clinical guidelines

## Technical Details

### System Configuration
- **Memory**: 8GB RAM for 100K patient generation
- **CPU**: 4 vCPU for optimal performance
- **Timeout**: 2 hours maximum execution time
- **Estimated Runtime**: 30-60 minutes for 100K patients

### File Structure
```
output/
├── csv/
│   └── [timestamp]/
│       ├── patients.csv      # 100,000 patients
│       ├── encounters.csv    # ~2-5M encounters
│       ├── conditions.csv    # ~500K-1M conditions
│       ├── medications.csv   # ~1-3M medications
│       └── ...
├── fhir/
│   └── [patient_bundles]/    # Individual FHIR bundles
└── metadata/
    └── [run_info].json       # Generation metadata
```

## Testing

The system includes comprehensive unit tests:

```bash
cd services/synthea_runner
python3 -m pytest test_runner.py -v          # Core functionality
python3 -m pytest test_entrypoint.py -v      # Environment handling
python3 test_vancouver_hybrid.py             # Vancouver generation test
```

## Use Cases

### Healthcare Analytics
- **Population Health**: Analyze disease patterns across 100K patients
- **Quality Metrics**: Calculate quality measures and outcomes
- **Risk Stratification**: Identify high-risk patient populations
- **Cost Analysis**: Analyze healthcare utilization and costs

### Machine Learning
- **Feature Engineering**: Extract features from complete medical histories
- **Predictive Modeling**: Train models on realistic patient trajectories
- **Outcome Prediction**: Predict readmissions, complications, mortality
- **Drug Safety**: Analyze medication effects and interactions

### System Testing
- **Performance Testing**: Test systems with realistic patient loads
- **Integration Testing**: Validate FHIR and CSV import pipelines
- **Security Testing**: Test with realistic but safe synthetic data
- **Scalability Testing**: Validate system performance at scale

## Data Schema

### patients.csv
```csv
Id,BIRTHDATE,DEATHDATE,SSN,DRIVERS,PASSPORT,PREFIX,FIRST,LAST,SUFFIX,MAIDEN,MARITAL,RACE,ETHNICITY,GENDER,BIRTHPLACE,ADDRESS,CITY,STATE,COUNTY,ZIP,LAT,LON,HEALTHCARE_EXPENSES,HEALTHCARE_COVERAGE
```

### encounters.csv  
```csv
Id,START,STOP,PATIENT,ORGANIZATION,PROVIDER,PAYER,ENCOUNTERCLASS,CODE,DESCRIPTION,BASE_ENCOUNTER_COST,TOTAL_CLAIM_COST,PAYER_COVERAGE,REASONCODE,REASONDESCRIPTION
```

### conditions.csv
```csv
START,STOP,PATIENT,ENCOUNTER,CODE,DESCRIPTION
```

## Advanced Configuration

### Environment Variables
- `COUNT=100000` - Number of patients to generate
- `SEED=2024` - Random seed for reproducibility  
- `MAX_QPS=5` - API rate limit for FHIR uploads
- `DRY_RUN=false` - Set to true to skip FHIR upload

### Scaling Up
To generate more patients, modify the deployment script:
```bash
# For 500K patients (requires more memory/time)
--memory=16Gi --cpu=8 --task-timeout=14400s
--set-env-vars '...COUNT=500000...'
```

## Troubleshooting

### Common Issues
1. **Out of Memory**: Increase memory allocation for large patient counts
2. **Timeout**: Increase task timeout for large generations
3. **API Limits**: Reduce MAX_QPS if hitting FHIR API limits

### Monitoring
```bash
# Check job status
gcloud run jobs executions list --job=synthea-runner-vancouver-100k

# View logs
gcloud logs read --project=$PROJECT_ID --filter="resource.labels.job_name=synthea-runner-vancouver-100k"

# Check resource usage
gcloud run jobs executions describe [EXECUTION_ID] --region=$REGION
```

## Contact

For issues or questions about the Vancouver patient generation system, please check:
1. Unit tests for functionality validation
2. Existing documentation in `docs/README_Synthea_CAN.md`
3. GitHub issues for known problems