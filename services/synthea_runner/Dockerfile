# syntax=docker/dockerfile:1.6
FROM python:3.11-slim AS base

# Install Java runtime for Synthea and build tools
RUN apt-get update && apt-get install -y --no-install-recommends openjdk-21-jdk-headless curl ca-certificates unzip && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy runner code (paths relative to repo root build context)
COPY services/synthea_runner/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY services/synthea_runner /app/services/synthea_runner

# Fetch Synthea assets at build time
# Download Synthea jar
RUN mkdir -p /app/synthea/downloads /app/synthea/resources /app/synthea/config /app/synthea/output
ARG SYNTH_VERSION=v3.0.0
ARG SYNTH_JAR=synthea-with-dependencies.jar
RUN curl -fsSL -o /app/synthea/downloads/${SYNTH_JAR} \
    https://github.com/synthetichealth/synthea/releases/download/${SYNTH_VERSION}/${SYNTH_JAR}

# Copy Canada geography (and optional payers/providers) from repo
RUN mkdir -p /app/synthea/resources/geography /app/synthea/resources/payers /app/synthea/resources/providers /app/synthea/resources/modules
# Copy Synthea resources from repo (both US and CA live here)
COPY synthea/src/main/resources/geography/ /app/synthea/resources/geography/
COPY synthea/src/main/resources/payers/ /app/synthea/resources/payers/
COPY synthea/src/main/resources/providers/ /app/synthea/resources/providers/
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
  > /app/synthea/config/synthea-canada.properties

ENV PYTHONUNBUFFERED=1
ENV PORT=8080

# Default to job mode unless overridden
ENV MODE=job
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=80.0 -Xms512m"
CMD ["python", "-m", "services.synthea_runner.entrypoint"]
