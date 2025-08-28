#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<'EOF'
fill_env.sh — generate or update .env for Hospigen (pre‑Synthea)

Usage:
  bash scripts/fill_env.sh [--yes]

Options:
  --yes      Non-interactive. Accept detected defaults where possible.
             You can still override by exporting env vars before running.

Environment overrides (optional):
  PROJECT_ID, REGION, DATASET_ID, STORE_ID, BRIDGE_SERVICE, BRIDGE_URL, PUSH_SA
EOF
}

non_interactive="false"
if [[ "${1:-}" == "--help" ]]; then usage; exit 0; fi
if [[ "${1:-}" == "--yes" ]]; then non_interactive="true"; fi

# Helpers
prompt() {
  local var="$1"; local prompt_text="$2"; local default="${3:-}"
  local value="${!var:-}"
  if [[ -n "$value" ]]; then
    echo "$var already set: $value"
    return 0
  fi
  if [[ "$non_interactive" == "true" ]]; then
    if [[ -n "$default" ]]; then
      printf -v "$var" "%s" "$default"
      export "$var"
      echo "Using default for $var: ${!var}"
      return 0
    else
      echo "Non-interactive mode requires $var but no default was found." >&2
      exit 1
    fi
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$prompt_text [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$prompt_text: " value
    if [[ -z "$value" ]]; then
      echo "A value is required." >&2
      exit 1
    fi
  fi
  printf -v "$var" "%s" "$value"
  export "$var"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

require_cmd gcloud

# 1) Detect PROJECT_ID and REGION
detect_project="$(gcloud config get-value project 2>/dev/null || true)"
detect_region="$(gcloud config get-value run/region 2>/dev/null || true)"
default_project="${PROJECT_ID:-${detect_project:-hospigen}}"
default_region="${REGION:-${detect_region:-northamerica-northeast1}}"

prompt PROJECT_ID "GCP Project ID" "$default_project"
prompt REGION "Region for resources" "$default_region"

# 2) Datasets in region
dataset_choices=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # Expect full path: projects/<p>/locations/<r>/datasets/<id>
  ds_id="${line##*/}"
  dataset_choices+=("$ds_id|$line")
done < <(gcloud healthcare datasets list --location="$REGION" --project="$PROJECT_ID" --format="value(name)" 2>/dev/null || true)

select_from_list() {
  local var="$1"; local title="$2"; shift 2
  local -a items=("$@")
  if [[ "${#items[@]}" -eq 0 ]]; then
    echo "No existing $title found."
    return 1
  fi
  if [[ "$non_interactive" == "true" ]]; then
    IFS='|' read -r chosen_id chosen_path <<< "${items[0]}"
    printf -v "$var" "%s" "$chosen_id"
    export "$var"
    printf -v "${var}_PATH" "%s" "$chosen_path"
    export "${var}_PATH"
    echo "Using $title: ${!var}"
    return 0
  fi
  echo "$title:"
  local i=1
  for it in "${items[@]}"; do
    IFS='|' read -r id path <<< "$it"
    printf "  %2d) %s\n" "$i" "$id"
    ((i++))
  done
  read -r -p "Select number (or leave blank to enter manually): " choice
  if [[ -n "$choice" && "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#items[@]}" ]]; then
    IFS='|' read -r chosen_id chosen_path <<< "${items[$((choice-1))]}"
    printf -v "$var" "%s" "$chosen_id"
    export "$var"
    printf -v "${var}_PATH" "%s" "$chosen_path"
    export "${var}_PATH"
  else
    read -r -p "Enter $title ID: " manual
    if [[ -z "$manual" ]]; then
      echo "A value is required." >&2
      exit 1
    fi
    printf -v "$var" "%s" "$manual"
    export "$var"
    printf -v "${var}_PATH" "projects/%s/locations/%s/datasets/%s" "$PROJECT_ID" "$REGION" "$manual"
    export "${var}_PATH"
  fi
}

if [[ -z "${DATASET_ID:-}" ]]; then
  if ! select_from_list DATASET_ID "Healthcare Dataset" "${dataset_choices[@]}"; then
    prompt DATASET_ID "Enter Healthcare Dataset ID" ""
    export DATASET_ID_PATH="projects/${PROJECT_ID}/locations/${REGION}/datasets/${DATASET_ID}"
  fi
fi

# 3) FHIR stores in dataset
fhir_choices=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  fs_id="${line##*/}"
  fhir_choices+=("$fs_id|$line")
done < <(gcloud healthcare fhir-stores list --dataset="${DATASET_ID_PATH}" --location="$REGION" --format="value(name)" 2>/dev/null || true)

if [[ -z "${STORE_ID:-}" ]]; then
  if ! select_from_list STORE_ID "FHIR Store" "${fhir_choices[@]}"; then
    prompt STORE_ID "Enter FHIR Store ID" ""
    export STORE_ID_PATH="${DATASET_ID_PATH}/fhirStores/${STORE_ID}"
  else
    export STORE_ID_PATH="${DATASET_ID_PATH}/fhirStores/${STORE_ID}"
  fi
fi

# 4) Cloud Run Bridge service
run_services=()
while IFS= read -r svc; do
  [[ -z "$svc" ]] && continue
  run_services+=("$svc")
done < <(gcloud run services list --region="$REGION" --project="$PROJECT_ID" --format="value(name)" 2>/dev/null || true)

detect_bridge="${BRIDGE_SERVICE:-}"
if [[ -z "$detect_bridge" && "${#run_services[@]}" -gt 0 ]]; then
  if [[ "$non_interactive" == "true" ]]; then
    detect_bridge="${run_services[0]}"
  else
    echo "Cloud Run services:"
    i=1; for s in "${run_services[@]}"; do printf "  %2d) %s\n" "$i" "$s"; ((i++)); done
    read -r -p "Select Bridge service number (or leave blank to enter manually): " s_choice
    if [[ -n "$s_choice" && "$s_choice" =~ ^[0-9]+$ && "$s_choice" -ge 1 && "$s_choice" -le "${#run_services[@]}" ]]; then
      detect_bridge="${run_services[$((s_choice-1))]}"
    fi
  fi
fi
prompt BRIDGE_SERVICE "Cloud Run service name for Bridge" "${detect_bridge:-}"

# 5) Bridge URL
detect_url="$(gcloud run services describe "$BRIDGE_SERVICE" --region="$REGION" --project="$PROJECT_ID" --format="value(status.url)" 2>/dev/null || true)"
prompt BRIDGE_URL "Bridge HTTPS URL" "${BRIDGE_URL:-${detect_url:-}}"

# 6) Push SA
default_push_sa="${PUSH_SA:-bridge-push@${PROJECT_ID}.iam.gserviceaccount.com}"
prompt PUSH_SA "Pub/Sub push service account" "$default_push_sa"

# Write .env
if [[ -f "$ENV_FILE" ]]; then
  cp "$ENV_FILE" "${ENV_FILE}.${BACKUP_SUFFIX}.bak"
  echo "Backed up existing $ENV_FILE to ${ENV_FILE}.${BACKUP_SUFFIX}.bak"
fi

cat > "$ENV_FILE" <<EOF
# Generated by scripts/fill_env.sh on $(date -Iseconds)
export PROJECT_ID=${PROJECT_ID}
export REGION=${REGION}

export DATASET_ID=${DATASET_ID}
export STORE_ID=${STORE_ID}

export BRIDGE_SERVICE=${BRIDGE_SERVICE}
export BRIDGE_URL=${BRIDGE_URL}
export PUSH_SA=${PUSH_SA}
EOF

echo "Wrote $ENV_FILE"
echo "Next:"
echo "  source .env"
echo "  gcloud config set project \"${PROJECT_ID}\""
