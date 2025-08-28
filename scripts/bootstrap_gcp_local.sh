#!/usr/bin/env bash
set -euo pipefail

# bootstrap_gcp.sh — Install Google Cloud CLI, authenticate, set config, enable APIs, and wire Hospigen env.

usage() {
  cat <<'EOF'
bootstrap_gcp.sh — Install Google Cloud CLI, authenticate, set config, enable APIs, set ADC quota project, and wire Hospigen env.

Usage:
  bash scripts/bootstrap_gcp.sh [options]

Options:
  --install-cli           Install Google Cloud CLI (Debian/Ubuntu). Skipped if gcloud exists.
  --account EMAIL         Google account email to authenticate (e.g., andriy.ignatov@gmail.com).
  --no-browser            Use device login (prints URL) instead of opening a browser.
  --adc                   Also perform Application Default Credentials login.
  --set-adc-quota         Set ADC quota project to the selected project (recommended).
  --project PROJECT_ID    Set gcloud project. If omitted, you'll be prompted to choose.
  --region REGION         Set default run/region (default: northamerica-northeast1).
  --enable-apis           Enable required APIs (Healthcare, Pub/Sub, Run).
  --write-env             Run scripts/fill_env.sh --yes to generate .env (uses PROJECT_ID/REGION from config or flags).
  --wire-infra            Apply topics, set FHIR notifications, and create push subscription.
  --yes                   Non-interactive where possible.
  --print-summary         Print detected config at the end (default; disable via --no-print-summary).
  --no-print-summary      Do not print summary.
  --help                  Show this help.

Examples:
  bash scripts/bootstrap_gcp.sh \
    --install-cli \
  --account user@gmail.com \
    --adc \
  --set-adc-quota \
    --project hospigen \
    --region northamerica-northeast1 \
    --enable-apis \
    --write-env \
    --wire-infra
EOF
}

log() { echo "[bootstrap] $*"; }
err() { echo "[bootstrap:ERROR] $*" >&2; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}

# Temporarily allow prompts for gcloud even when --yes was used
with_prompts() {
  local old_prompt="${CLOUDSDK_CORE_DISABLE_PROMPTS-}"
  if [[ -n "$old_prompt" ]]; then unset CLOUDSDK_CORE_DISABLE_PROMPTS; fi
  "$@"
  local rc=$?
  if [[ -n "$old_prompt" ]]; then export CLOUDSDK_CORE_DISABLE_PROMPTS="$old_prompt"; fi
  return $rc
}

on_debian_like() {
  [[ -f /etc/debian_version ]] || [[ -f /etc/lsb-release ]]
}

install_cli_debian() {
  log "Installing Google Cloud CLI via apt (requires sudo)"
  require_cmd sudo
  sudo apt-get update -y
  sudo apt-get install -y apt-transport-https ca-certificates gnupg curl
  if [[ ! -f /usr/share/keyrings/cloud.google.gpg ]]; then
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  fi
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y google-cloud-cli
  gcloud --version || { err "gcloud installation failed"; exit 1; }
}

ensure_gcloud() {
  if command -v gcloud >/dev/null 2>&1; then
    log "gcloud already installed: $(gcloud --version | head -n1)"
    return 0
  fi
  if [[ "$do_install_cli" == true ]]; then
    if on_debian_like; then
      install_cli_debian
    else
      err "--install-cli currently supports Debian/Ubuntu. Install gcloud manually: https://cloud.google.com/sdk/docs/install"
      exit 1
    fi
  else
    err "gcloud not found. Re-run with --install-cli or install manually."
    exit 1
  fi
}

gcloud_auth_login() {
  # If a placeholder account was provided, stop early with a helpful error
  if [[ -n "$account" && "$account" == *"<"*">"* ]]; then
    err "Replace --account with your real Google email instead of $account"
    exit 1
  fi
  # If already authenticated, skip unless a specific account was requested
  local active_acct
  active_acct="$(gcloud auth list --filter='status:ACTIVE' --format='value(account)' 2>/dev/null || true)"
  if [[ -n "$active_acct" && -z "$account" ]]; then
    log "Already authenticated as $active_acct"
    return 0
  fi
  local acct_flag=( )
  if [[ -n "$account" ]]; then acct_flag=("$account"); fi
  local browser_flag=( )
  if [[ "$do_no_browser" == true ]]; then browser_flag=("--no-launch-browser"); fi
  log "Starting gcloud auth login ${account:+for $account}"
  with_prompts gcloud auth login "${acct_flag[@]}" "${browser_flag[@]}"
}

gcloud_adc_login() {
  local browser_flag=( )
  if [[ "$do_no_browser" == true ]]; then browser_flag=("--no-launch-browser"); fi
  log "Starting gcloud application-default login"
  with_prompts gcloud auth application-default login "${browser_flag[@]}"
}

set_config() {
  if [[ -n "$account" ]]; then
    log "Setting active account: $account"
    gcloud config set account "$account" >/dev/null
  fi
  if [[ -n "$project" ]]; then
    log "Setting project: $project"
    gcloud config set project "$project" >/dev/null
  fi
  if [[ -n "$region" ]]; then
    log "Setting run/region: $region"
    gcloud config set run/region "$region" >/dev/null
  fi
}

# Prompt to choose a project if not provided and not configured
choose_project() {
  local current_proj="$(gcloud config get-value project 2>/dev/null || true)"
  if [[ -n "$project" || -n "$current_proj" ]]; then
    # Either provided via flag or already configured
    return 0
  fi
  log "No project configured. Fetching available projects..."
  mapfile -t PROJS < <(gcloud projects list --filter='lifecycleState:ACTIVE' --format='value(projectId)' 2>/dev/null || true)
  if [[ ${#PROJS[@]} -eq 0 ]]; then
    err "No active projects found for the authenticated account. Create one or provide --project."
    exit 1
  fi
  if [[ "$assume_yes" == true ]]; then
    project="${PROJS[0]}"
    log "Using first project (non-interactive): $project"
    return 0
  fi
  echo "Projects:"
  local i=1
  for p in "${PROJS[@]}"; do printf "  %2d) %s\n" "$i" "$p"; ((i++)); done
  read -r -p "Select project number (or type a project ID): " choice
  if [[ -n "$choice" && "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#PROJS[@]} ]]; then
    project="${PROJS[$((choice-1))]}"
  else
    project="$choice"
  fi
  if [[ -z "$project" ]]; then
    err "Project selection is required."
    exit 1
  fi
}

verify_project_access() {
  local proj
  proj="${project:-$(gcloud config get-value project 2>/dev/null)}"
  if [[ -z "$proj" ]]; then
    err "No project set to verify access."
    return 1
  fi
  if ! gcloud projects describe "$proj" >/dev/null 2>&1; then
    err "You do not have access to project [$proj] or it does not exist. Provide a valid --project or create one."
    return 1
  fi
}

enable_required_apis() {
  local proj
  proj="${project:-$(gcloud config get-value project 2>/dev/null)}"
  if [[ -z "$proj" ]]; then err "No project set for enabling APIs"; exit 1; fi
  log "Enabling APIs on project $proj"
  gcloud services enable \
    healthcare.googleapis.com \
    pubsub.googleapis.com \
    run.googleapis.com \
    --project "$proj"
}

set_adc_quota_project() {
  local proj
  proj="${project:-$(gcloud config get-value project 2>/dev/null)}"
  if [[ -z "$proj" ]]; then err "No project set to configure ADC quota project"; return 1; fi
  # Only attempt if ADC exists or user requested it
  if [[ -f "$HOME/.config/gcloud/application_default_credentials.json" || "$do_set_adc_quota" == true || "$do_adc" == true ]]; then
    log "Setting ADC quota project to $proj"
    gcloud auth application-default set-quota-project "$proj" || true
  fi
}

write_env_file() {
  local proj region_cfg
  proj="${project:-$(gcloud config get-value project 2>/dev/null)}"
  region_cfg="${region:-$(gcloud config get-value run/region 2>/dev/null)}"
  if [[ -z "$proj" || -z "$region_cfg" ]]; then
    err "PROJECT_ID or REGION missing; cannot write .env. Provide --project/--region or set via gcloud config."
    exit 1
  fi
  log "Generating .env via scripts/fill_env.sh --yes"
  export PROJECT_ID="$proj"
  export REGION="$region_cfg"
  if [[ -f scripts/fill_env.sh ]]; then
    bash scripts/fill_env.sh --yes
  else
    err "scripts/fill_env.sh not found"
    exit 1
  fi
}

wire_infrastructure() {
  log "Applying Pub/Sub topics from contracts/schemas/topics.yaml"
  bash scripts/apply_topics.sh contracts/schemas/topics.yaml

  log "Configuring FHIR notifications to publish to fhir.changes"
  bash scripts/setup_fhir_notifications.sh

  log "Creating push subscription to Bridge"
  bash scripts/create_push_subscription.sh
}

print_summary() {
  local acct proj reg url
  acct="$(gcloud config get-value account 2>/dev/null || true)"
  proj="$(gcloud config get-value project 2>/dev/null || true)"
  reg="$(gcloud config get-value run/region 2>/dev/null || true)"
  url="$( [[ -f .env ]] && grep -E '^export[[:space:]]+BRIDGE_URL=' .env | head -n1 | cut -d'=' -f2- || true )"
  echo
  echo "Summary:";
  echo "  ACCOUNT     = ${acct:-<unset>}"
  echo "  PROJECT_ID  = ${proj:-<unset>}"
  echo "  REGION      = ${reg:-<unset>}"
  [[ -n "$url" ]] && echo "  BRIDGE_URL  = $url"
}

# Defaults
do_install_cli=false
do_no_browser=false
do_adc=false
enable_apis=false
write_env=false
wire_infra=false
assume_yes=false
do_print_summary=true
do_set_adc_quota=false

account=""
project="hospigen"
region="northamerica-northeast1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-cli) do_install_cli=true; shift ;;
    --account) account="${2:-}"; shift 2 ;;
    --no-browser) do_no_browser=true; shift ;;
    --adc) do_adc=true; shift ;;
  --set-adc-quota) do_set_adc_quota=true; shift ;;
    --project) project="${2:-}"; shift 2 ;;
    --region) region="${2:-}"; shift 2 ;;
    --enable-apis) enable_apis=true; shift ;;
    --write-env) write_env=true; shift ;;
    --wire-infra) wire_infra=true; shift ;;
    --yes) assume_yes=true; export CLOUDSDK_CORE_DISABLE_PROMPTS=1; shift ;;
    --print-summary) do_print_summary=true; shift ;;
    --no-print-summary) do_print_summary=false; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# 1) Ensure gcloud
ensure_gcloud

# 2) Authenticate
gcloud_auth_login || true
if [[ "$do_adc" == true ]]; then gcloud_adc_login || true; fi

# 3) Project selection (prompt if missing), then config
choose_project
set_config
if ! verify_project_access; then
  if [[ "$assume_yes" == true ]]; then
    err "Project [$project] is not accessible. Re-run with a valid --project or remove default project in the script."
    exit 1
  else
    log "Project [$project] not accessible. Allowing you to choose an accessible project..."
    project="" # reset to trigger selection
    choose_project
    set_config
    verify_project_access || { err "Still no access to selected project. Exiting."; exit 1; }
  fi
fi

# 3b) Set ADC quota project if requested or ADC exists
if [[ "$do_set_adc_quota" == true || "$do_adc" == true ]]; then set_adc_quota_project || true; fi

# 4) Enable APIs
if [[ "$enable_apis" == true ]]; then enable_required_apis; fi

# 5) Generate .env
if [[ "$write_env" == true ]]; then write_env_file; fi

# 6) Wire infra
if [[ "$wire_infra" == true ]]; then wire_infrastructure; fi

# 7) Summary
if [[ "$do_print_summary" == true ]]; then print_summary; fi

log "Done."
