#!/usr/bin/env bash
set -euo pipefail

# Usage: bash scripts/apply_topics.sh [path/to/topics.yaml]
# Env override: TOPICS_FILE=... bash scripts/apply_topics.sh

# Load env
if [ -f .env ]; then source .env; fi
: "${PROJECT_ID:?PROJECT_ID is required}"
: "${REGION:?REGION is required}"

gcloud config set project "$PROJECT_ID" >/dev/null

# Resolve topics file
TF="${TOPICS_FILE:-${1:-}}"
if [[ -z "${TF}" ]]; then
  for cand in "topics.yaml" "contracts/schemas/topics.yaml" "contracts/topics.yaml"; do
    if [[ -f "$cand" ]]; then TF="$cand"; break; fi
  done
fi
if [[ -z "${TF}" || ! -f "${TF}" ]]; then
  echo "topics.yaml not found. Pass path: bash scripts/apply_topics.sh contracts/schemas/topics.yaml" >&2
  exit 1
fi

echo "Using topics file: ${TF}"

# Create topics from YAML (yq preferred; awk fallback)
if command -v yq >/dev/null 2>&1; then
  mapfile -t TOPICS < <(yq -r '.topics[]' "${TF}")
else
  echo "yq not found; using awk fallback"
  mapfile -t TOPICS < <(awk '/^- /{print $2}' "${TF}")
fi

for t in "${TOPICS[@]}"; do
  echo "Ensuring topic: $t"
  gcloud pubsub topics create "$t" 2>/dev/null || echo "Exists: $t"
done

echo "Done."
