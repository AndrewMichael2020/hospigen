#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
BACKUP_SUFFIX="$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<'EOF'
fill_env.sh — generate or update .env for Hospigen

Usage:
  bash scripts/fill_env.sh [options]

Options:
  --yes                   Non-interactive. Accept defaults where possible.
  --offline|--minimal     Do not use gcloud; skip all API queries and use provided or safe defaults.
  --project ID            GCP project ID.
  --region REGION         GCP region (default: northamerica-northeast1).
  --dataset ID            Healthcare dataset ID.
  --store ID              FHIR store ID.
  --bridge-service NAME   Cloud Run Bridge service name.
  --bridge-url URL        Bridge service HTTPS URL.
  --push-sa EMAIL         Pub/Sub push service account email.
  --help                  Show help.

Also supports environment overrides:
  PROJECT_ID, REGION, DATASET_ID, STORE_ID, BRIDGE_SERVICE, BRIDGE_URL, PUSH_SA
EOF
}

non_interactive="false"
offline_mode="false"

# CLI overrides (initialized from env if present)
# Capture explicit environment overrides BEFORE reading existing .env
PROJECT_ID_OVR="${PROJECT_ID:-}"
REGION_OVR="${REGION:-}"
DATASET_ID_OVR="${DATASET_ID:-}"
STORE_ID_OVR="${STORE_ID:-}"
BRIDGE_SERVICE_OVR="${BRIDGE_SERVICE:-}"
BRIDGE_URL_OVR="${BRIDGE_URL:-}"
PUSH_SA_OVR="${PUSH_SA:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --yes) non_interactive="true"; shift ;;
    --offline|--minimal) offline_mode="true"; shift ;;
    --project) PROJECT_ID_OVR="${2:-}"; shift 2 ;;
    --region) REGION_OVR="${2:-}"; shift 2 ;;
    --dataset) DATASET_ID_OVR="${2:-}"; shift 2 ;;
    --store) STORE_ID_OVR="${2:-}"; shift 2 ;;
    --bridge-service) BRIDGE_SERVICE_OVR="${2:-}"; shift 2 ;;
    --bridge-url) BRIDGE_URL_OVR="${2:-}"; shift 2 ;;
    --push-sa) PUSH_SA_OVR="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# Now load existing .env for defaults (not as overrides)
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

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

gcloud_available() {
  command -v gcloud >/dev/null 2>&1
}

# Only require gcloud if not in offline mode
if [[ "$offline_mode" != "true" ]]; then
  if ! gcloud_available; then
    echo "gcloud is not available; falling back to offline mode." >&2
    offline_mode="true"
  fi
fi

# 1) Detect PROJECT_ID and REGION
detect_project=""
detect_region=""
if [[ "$offline_mode" != "true" ]] && gcloud_available; then
  detect_project="$(gcloud config get-value project 2>/dev/null || true)"
  detect_region="$(gcloud config get-value run/region 2>/dev/null || true)"
fi
default_project="${PROJECT_ID_OVR:-${detect_project:-hospigen}}"
default_region="${REGION_OVR:-${detect_region:-northamerica-northeast1}}"

prompt PROJECT_ID "GCP Project ID" "$default_project"
prompt REGION "Region for resources" "$default_region"

# 2) Datasets in region
dataset_choices=()
if [[ "$offline_mode" != "true" ]] && gcloud_available; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Expect full path: projects/<p>/locations/<r>/datasets/<id>
    ds_id="${line##*/}"
    dataset_choices+=("$ds_id|$line")
  done < <(gcloud healthcare datasets list --location="$REGION" --project="$PROJECT_ID" --format="value(name)" 2>/dev/null || true)
fi

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

if [[ -z "${DATASET_ID_OVR}" && -z "${DATASET_ID:-}" ]]; then
  if ! select_from_list DATASET_ID "Healthcare Dataset" "${dataset_choices[@]}"; then
    # Use override if provided, else choose sensible default in non-interactive/offline
    if [[ -n "$DATASET_ID_OVR" ]]; then
      DATASET_ID="$DATASET_ID_OVR"
    else
      def_ds="hospigen"
      if [[ "$non_interactive" == "true" ]]; then
        DATASET_ID="$def_ds"
        echo "Using default dataset ID: $DATASET_ID"
      else
        prompt DATASET_ID "Enter Healthcare Dataset ID" "$def_ds"
      fi
    fi
    export DATASET_ID_PATH="projects/${PROJECT_ID}/locations/${REGION}/datasets/${DATASET_ID}"
  fi
else
  DATASET_ID="${DATASET_ID_OVR:-${DATASET_ID}}"
  export DATASET_ID_PATH="projects/${PROJECT_ID}/locations/${REGION}/datasets/${DATASET_ID}"
fi

# 3) FHIR stores in dataset
fhir_choices=()
if [[ "$offline_mode" != "true" ]] && gcloud_available; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    fs_id="${line##*/}"
    fhir_choices+=("$fs_id|$line")
  done < <(gcloud healthcare fhir-stores list --dataset="${DATASET_ID_PATH}" --location="$REGION" --format="value(name)" 2>/dev/null || true)
fi

if [[ -z "${STORE_ID_OVR}" && -z "${STORE_ID:-}" ]]; then
  if ! select_from_list STORE_ID "FHIR Store" "${fhir_choices[@]}"; then
    if [[ -n "$STORE_ID_OVR" ]]; then
      STORE_ID="$STORE_ID_OVR"
    else
      def_store="hospigen-fhir"
      if [[ "$non_interactive" == "true" ]]; then
        STORE_ID="$def_store"
        echo "Using default FHIR store ID: $STORE_ID"
      else
        prompt STORE_ID "Enter FHIR Store ID" "$def_store"
      fi
    fi
  fi
  export STORE_ID_PATH="${DATASET_ID_PATH}/fhirStores/${STORE_ID}"
else
  STORE_ID="${STORE_ID_OVR:-${STORE_ID}}"
  export STORE_ID_PATH="${DATASET_ID_PATH}/fhirStores/${STORE_ID}"
fi

# 4) Cloud Run Bridge service
run_services=()
if [[ "$offline_mode" != "true" ]] && gcloud_available; then
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    run_services+=("$svc")
  done < <(gcloud run services list --region="$REGION" --project="$PROJECT_ID" --format="value(name)" 2>/dev/null || true)
fi

detect_bridge="${BRIDGE_SERVICE_OVR:-${BRIDGE_SERVICE:-}}"
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
if [[ -z "$detect_bridge" ]]; then
  # If we discovered exactly one service, use it non-interactively
  if [[ "${#run_services[@]}" -eq 1 ]]; then
    BRIDGE_SERVICE="${run_services[0]}"
    echo "Using discovered Cloud Run service: $BRIDGE_SERVICE"
  elif [[ "${#run_services[@]}" -gt 1 && "$non_interactive" == "true" ]]; then
    # Heuristic: pick the only service containing 'bridge' if unique
    mapfile -t _bridge_candidates < <(printf '%s
' "${run_services[@]}" | grep -i 'bridge' || true)
    if [[ "${#_bridge_candidates[@]}" -eq 1 ]]; then
      BRIDGE_SERVICE="${_bridge_candidates[0]}"
      echo "Using Cloud Run service by heuristic: $BRIDGE_SERVICE"
    else
      BRIDGE_SERVICE="bridge"
      echo "Multiple services found; defaulting to: $BRIDGE_SERVICE"
    fi
  elif [[ "$non_interactive" == "true" ]]; then
    BRIDGE_SERVICE="bridge"
    echo "Using default Bridge service name: $BRIDGE_SERVICE"
  else
    def_bridge="bridge"
    prompt BRIDGE_SERVICE "Cloud Run service name for Bridge" "$def_bridge"
  fi
else
  BRIDGE_SERVICE="$detect_bridge"
fi
export BRIDGE_SERVICE

# 5) Bridge URL
resolve_bridge_url() {
  local svc="$1"; local reg="$2"; local proj="$3"
  local url=""
  # First try describe
  url="$(gcloud run services describe "$svc" --region="$reg" --project="$proj" --format='value(status.url)' 2>/dev/null || true)"
  if [[ -n "$url" ]]; then echo "$url"; return 0; fi
  # Fallback: list and filter by name
  url="$(gcloud run services list --region="$reg" --project="$proj" --filter="metadata.name=$svc" --format='value(status.url)' 2>/dev/null || true)"
  if [[ -n "$url" ]]; then echo "$url"; return 0; fi
  return 1
}

detect_url=""
if [[ -n "${BRIDGE_URL_OVR}" ]]; then
  BRIDGE_URL="$BRIDGE_URL_OVR"
else
  if [[ "$offline_mode" != "true" ]] && gcloud_available; then
    detect_url="$(resolve_bridge_url "$BRIDGE_SERVICE" "$REGION" "$PROJECT_ID" || true)"
  fi
  if [[ -n "$detect_url" ]]; then
    BRIDGE_URL="$detect_url"
  else
    if [[ "$non_interactive" == "true" ]]; then
      echo "Warning: Could not auto-detect Bridge URL for service '$BRIDGE_SERVICE' in region '$REGION' and project '$PROJECT_ID'." >&2
      echo "         Provide --bridge-url or ensure the service exists. Writing placeholder for now." >&2
      BRIDGE_URL="https://your-bridge-url"
    else
      prompt BRIDGE_URL "Bridge HTTPS URL" "${BRIDGE_URL:-}"
    fi
  fi
fi
export BRIDGE_URL

# 6) Push SA
default_push_sa="${PUSH_SA_OVR:-${PUSH_SA:-bridge-push@${PROJECT_ID}.iam.gserviceaccount.com}}"
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
