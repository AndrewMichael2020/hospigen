#!/usr/bin/env bash
set -euo pipefail

# Load env
if [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${REGION:?REGION is required}"

gcloud config set project "$PROJECT_ID" >/dev/null

# Create topics from topics.yaml (uses yq if present, otherwise awk fallback)
if command -v yq >/dev/null 2>&1; then
  mapfile -t TOPICS < <(yq -r '.topics[]' topics.yaml)
else
  echo "yq not found; using awk fallback"
  mapfile -t TOPICS < <(awk '/^- /{print $2}' topics.yaml)
fi

for t in "${TOPICS[@]}"; do
  echo "Ensuring topic: $t"
  gcloud pubsub topics create "$t" 2>/dev/null || echo "Exists: $t"
done

echo "Done."
