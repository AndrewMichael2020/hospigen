#!/usr/bin/env bash
# Generate 500 synthea patients, assign cities per distribution, convert to NDJSON and upload to GCS
# Places files under gs://<bucket>/<prefix>/ where prefix is created by gcs_prefix.sh

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS="${ROOT}/scripts"
GCS_PREFIX_SCRIPT="${SCRIPTS}/gcs_prefix.sh"
GEN_SCRIPT="${SCRIPTS}/extract_vancouver_500.py"

BUCKET=${BUCKET:-synthea-raw-hospigen}
OUT_DIR=${OUT_DIR:-${ROOT}/test_output_500}
TOTAL=${TOTAL:-500}
BATCH=${BATCH:-50}
SEED=${SEED:-42}
VERSION_LABEL=${VERSION_LABEL:-500_v1}

# Define city distribution here (editable): comma-separated CITY:percent (must sum to 100)
# Example: CITY_DISTRIBUTION="Surrey:50,New Westminster:25,Coquitlam:25"
CITY_DISTRIBUTION=${CITY_DISTRIBUTION:-"Surrey:50,New Westminster:25,Coquitlam:25"}

if [[ ! -x "$GCS_PREFIX_SCRIPT" ]]; then
  echo "Missing or non-executable: $GCS_PREFIX_SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$GEN_SCRIPT" ]]; then
  echo "Missing generator script: $GEN_SCRIPT" >&2
  exit 1
fi

DATE=$(date -u +"%Y-%m-%d")
VERSION="${VERSION_LABEL}_${DATE}"

# Create prefix and placeholder
PREFIX=$($GCS_PREFIX_SCRIPT --version "$VERSION" --bucket "$BUCKET" --create)
echo "Using GCS prefix: $PREFIX"

# Generate patients
echo "Running generator to create ${TOTAL} patients into ${OUT_DIR} (this may take a while)..."
python3 "$GEN_SCRIPT" --total "$TOTAL" --batch-size "$BATCH" --seed "$SEED" --out-dir "$OUT_DIR" --build-if-missing

# Find generated patient json files
json_files=("$(ls -1 ${OUT_DIR}/patient_*.json 2>/dev/null || true)")
if [[ -z "${json_files}" ]]; then
  echo "No generated patient JSON files found in ${OUT_DIR}" >&2
  exit 2
fi
# Create ordered list
mapfile -t PAT_FILES < <(ls -1 ${OUT_DIR}/patient_*.json | sort)
NUM=${#PAT_FILES[@]}
if [[ $NUM -lt $TOTAL ]]; then
  echo "Warning: generated only $NUM patients (requested $TOTAL)"
fi

# Parse CITY_DISTRIBUTION and compute counts
declare -A CITY_COUNTS
total_pct=0
IFS=',' read -r -a dist_parts <<< "$CITY_DISTRIBUTION"
for part in "${dist_parts[@]}"; do
  part_trim=$(echo "$part" | sed 's/^\s*//;s/\s*$//')
  city_name=$(echo "$part_trim" | awk -F: '{print $1}')
  pct=$(echo "$part_trim" | awk -F: '{print $2}')
  pct=${pct:-0}
  total_pct=$((total_pct + pct))
  CITY_COUNTS["$city_name"]=$pct
done
if [[ $total_pct -ne 100 ]]; then
  echo "CITY_DISTRIBUTION percentages must sum to 100 (got $total_pct)" >&2
  exit 3
fi

# Convert percentages to counts (rounding last city to make total match)
remaining=$NUM
assigned_total=0
declare -a CITY_ORDER
for part in "${dist_parts[@]}"; do
  part_trim=$(echo "$part" | sed 's/^\s*//;s/\s*$//')
  city_name=$(echo "$part_trim" | awk -F: '{print $1}')
  CITY_ORDER+=("$city_name")
done
for i_idx in "${!CITY_ORDER[@]}"; do
  city_name=${CITY_ORDER[$i_idx]}
  pct=${CITY_COUNTS[$city_name]}
  if [[ $i_idx -lt $((${#CITY_ORDER[@]} - 1)) ]]; then
    count=$(( (NUM * pct + 50) / 100 ))
    CITY_COUNTS["$city_name"]=$count
    assigned_total=$((assigned_total + count))
    remaining=$((NUM - assigned_total))
  else
    # last city gets remainder to ensure sum matches
    CITY_COUNTS["$city_name"]=$remaining
  fi
done

echo "Assigning cities (counts):"
for city_name in "${CITY_ORDER[@]}"; do
  echo "  $city_name -> ${CITY_COUNTS[$city_name]}"
done

# assign_city helper remains same but generic
assign_city(){
  local file="$1"
  local city="$2"
  python3 - <<PY
import json,sys
p='''$file'''
with open(p,'r',encoding='utf-8') as f:
    data=json.load(f)
changed=False
if isinstance(data,dict) and 'entry' in data:
    for entry in data['entry']:
        res=entry.get('resource')
        if not res: continue
        if 'address' in res:
            if isinstance(res['address'], list):
                for addr in res['address']:
                    addr['city']= '$city'
                    addr['state']='British Columbia'
                    addr['country']='CA'
                    changed=True
            elif isinstance(res['address'], dict):
                addr=res['address']
                addr['city']='$city'
                addr['state']='British Columbia'
                addr['country']='CA'
                changed=True
if changed:
    with open(p,'w',encoding='utf-8') as f:
        json.dump(data,f,indent=2,ensure_ascii=False)
PY
}

# Assign cities in order
i=0
for f in "${PAT_FILES[@]}"; do
  ((i++))
  # find which city this index belongs to
  cum=0
  for city_name in "${CITY_ORDER[@]}"; do
    cum=$((cum + CITY_COUNTS[$city_name]))
    if [[ $i -le $cum ]]; then
      assign_city "$f" "$city_name"
      break
    fi
  done
done

# Convert each JSON to NDJSON and upload, then delete local NDJSON
uploaded=0
for f in "${PAT_FILES[@]}"; do
  nd_local="${f%.json}.ndjson"
  python3 - <<PY
import json,sys
p='''$f'''
out='''$nd_local'''
with open(p,'r',encoding='utf-8') as fh:
    data=json.load(fh)
with open(out,'w',encoding='utf-8') as oh:
    if isinstance(data,dict) and 'entry' in data and isinstance(data['entry'],list):
        for entry in data['entry']:
            res=entry.get('resource')
            if res is None: continue
            oh.write(json.dumps(res,ensure_ascii=False,separators=(",",":"))+"\n")
    else:
        oh.write(json.dumps(data,ensure_ascii=False,separators=(",",":"))+"\n")
print(out)
PY
  # upload
  echo "Uploading ${nd_local} to gs://${BUCKET}/${PREFIX}/"
  gsutil cp "$nd_local" "gs://${BUCKET}/${PREFIX}/" || { echo "Upload failed for $nd_local" >&2; exit 4; }
  rm -f "$nd_local"
  ((uploaded++))
done

echo "Uploaded ${uploaded} NDJSON files to gs://${BUCKET}/${PREFIX}/"

# Optionally keep JSONs or remove
# echo "Removing local JSON files to save space"
# rm -f ${PAT_FILES[@]}

exit 0
