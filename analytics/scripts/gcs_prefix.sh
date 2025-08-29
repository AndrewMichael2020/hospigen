#!/usr/bin/env bash
# generate a predictable GCS prefix for patient data and optionally create a placeholder
# Usage:
#   ./gcs_prefix.sh [--prefix-base BASE] [--version VERSION] [--date DATE] [--bucket BUCKET] [--create] [--dry-run]
# Examples:
#   ./gcs_prefix.sh --version 500_v1_2025-08-29
#   ./gcs_prefix.sh --bucket synthea-raw-hospigen --create
# Outputs the prefix on stdout (no trailing slash)

set -euo pipefail

PREFIX_BASE="patients"
VERSION=""
DATE=""
BUCKET=""
CREATE=false
DRY_RUN=false

print_help() {
  cat <<'EOF'
Usage: gcs_prefix.sh [options]

Options:
  --prefix-base BASE   Base folder (default: patients)
  --version VERSION    Version or label (eg. 500_v1_2025-08-29). If omitted a timestamped label is used.
  --date DATE          Use explicit date string (overrides auto date portion)
  --bucket BUCKET      If set and --create is used, a placeholder will be written to the path.
  --create             Create a placeholder object at gs://<bucket>/<prefix>/_PLACEHOLDER
  --dry-run            Print what would be done but do not run gsutil
  -h, --help           Show this help

Example:
  ./gcs_prefix.sh --version 500_v1_2025-08-29 --bucket synthea-raw-hospigen --create
EOF
}

# parse args
while [[ ${#} -gt 0 ]]; do
  case "$1" in
    --prefix-base)
      PREFIX_BASE="$2"; shift 2;;
    --version)
      VERSION="$2"; shift 2;;
    --date)
      DATE="$2"; shift 2;;
    --bucket)
      BUCKET="$2"; shift 2;;
    --create)
      CREATE=true; shift 1;;
    --dry-run)
      DRY_RUN=true; shift 1;;
    -h|--help)
      print_help; exit 0;;
    *)
      echo "Unknown argument: $1" >&2; print_help; exit 2;;
  esac
done

# build timestamp/date
if [[ -z "$DATE" ]]; then
  DATE=$(date -u +"%Y-%m-%d_%H%M%SZ")
fi

if [[ -z "$VERSION" ]]; then
  VERSION="v1_${DATE}"
fi

# normalize prefix: remove leading/trailing slashes from components
normalize() {
  local s="$1"
  s="${s#/}"
  s="${s%/}"
  echo "$s"
}

PREFIX_BASE=$(normalize "$PREFIX_BASE")
VERSION=$(normalize "$VERSION")

PREFIX="${PREFIX_BASE}/${VERSION}_${DATE}"

# print the prefix (no trailing slash)
echo "$PREFIX"

# optionally create placeholder
if [[ "$CREATE" == true ]]; then
  if [[ -z "$BUCKET" ]]; then
    echo "--create set but no --bucket provided" >&2
    exit 3
  fi
  PLACEHOLDER="_PLACEHOLDER"
  DEST="gs://${BUCKET}/${PREFIX}/${PLACEHOLDER}"
  echo "Creating placeholder at ${DEST}"
  if [[ "$DRY_RUN" == true ]]; then
    echo "Dry run: would run: printf 'created by gcs_prefix' | gsutil cp - ${DEST}"
  else
    # attempt to write; capture gsutil errors
    if ! command -v gsutil >/dev/null 2>&1; then
      echo "gsutil not found in PATH; cannot create placeholder" >&2
      exit 4
    fi
    printf 'placeholder created by automation on %s\n' "$(date -u --iso-8601=seconds)" | gsutil -q cp - "${DEST}" || {
      echo "Failed to write placeholder to ${DEST}" >&2
      exit 5
    }
    echo "Placeholder created"
  fi
fi
