# syntax=docker/dockerfile:1.6
FROM python:3.11-slim AS base

# Install Java runtime for Synthea
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-17-jre-headless curl ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy runner code
COPY services/synthea_runner/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY services/synthea_runner /app/services/synthea_runner

# Fetch Synthea assets at build time
# Expect Canada resources present in repo under ./ca/src/main/resources
# Download Synthea jar
RUN mkdir -p /app/synthea/downloads /app/synthea/resources /app/synthea/config /app/synthea/output
ARG SYNTH_VERSION=v3.0.0
ARG SYNTH_JAR=synthea-with-dependencies.jar
RUN curl -fsSL -o /app/synthea/downloads/${SYNTH_JAR} \
    https://github.com/synthetichealth/synthea/releases/download/${SYNTH_VERSION}/${SYNTH_JAR}

# Copy Canada resources from repo if present (fallback to empty dirs)
COPY ca/src/main/resources/modules /app/synthea/resources/modules
COPY ca/src/main/resources/geography /app/synthea/resources/geography
# Baseline properties
RUN printf '%s\n' \
  'exporter.use_uuid_filenames=true' \
  'exporter.fhir.export=true' \
  'exporter.fhir.transaction_bundle=true' \
  'exporter.split_records=true' \
  'exporter.ccda.export=false' \
  'exporter.csv.export=false' \
  'exporter.fhir_stu3.export=false' \
  'exporter.fhir_dstu2.export=false' \
  'generate.geography.international=true' \
  'generate.geography.country_code=CAN' \
  > /app/synthea/config/synthea-canada.properties

ENV PYTHONUNBUFFERED=1
ENV PORT=8080

# Default to job mode unless overridden
ENV MODE=job
CMD ["python", "-m", "services.synthea_runner.entrypoint"]
