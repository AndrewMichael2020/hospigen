#!/usr/bin/env bash
set -euo pipefail

# Generate 1,000 synthetic patients for Greater Vancouver Area, British Columbia
# Output: JSON files in analytics/output/

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR="$SCRIPT_DIR/.."

echo "=== Vancouver Patient Generator ==="
echo "Generating 1,000 synthetic patients for Greater Vancouver Area..."
echo "Output directory: $SCRIPT_DIR/output/"
echo ""

# Check prerequisites
if ! command -v java >/dev/null 2>&1; then
    echo "Error: Java is required but not installed." >&2
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Error: Git is required but not installed." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: Python 3 is required but not installed." >&2
    exit 1
fi

# Run the generator
cd "$ROOT_DIR"
python3 "$SCRIPT_DIR/generate_vancouver_patients.py"

echo ""
echo "=== Generation Complete ==="
echo "Check analytics/output/ for the generated patient JSON files."