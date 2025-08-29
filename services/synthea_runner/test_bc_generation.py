#!/usr/bin/env python3
"""
Test script to validate Synthea runner with Canadian province (no city) for BC
"""

import os
import tempfile
import sys
from pathlib import Path

# Add current directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))

from runner import RunConfig, execute


def test_bc_province_generation():
    """Test generation of 5 patients for British Columbia province-wide"""
    print("Testing British Columbia province-wide patient generation...")
    
    # Create a temporary FHIR store path for testing
    fhir_store = "projects/test/locations/us-central1/datasets/test/fhirStores/test"
    
    cfg = RunConfig(
        province="British Columbia",
        city=None,  # No city - province-wide
        count=5,  # Small test count
        seed=12345,  # For reproducibility
        dry_run=True,  # Don't actually upload to FHIR store
        max_qps=1.0,
        fhir_store=fhir_store,
        country="CA"  # Test with Canada
    )
    
    print(f"Configuration:")
    print(f"  Province: {cfg.province}")
    print(f"  City: {cfg.city}")
    print(f"  Count: {cfg.count}")
    print(f"  Seed: {cfg.seed}")
    print(f"  Dry run: {cfg.dry_run}")
    print(f"  Country: {cfg.country}")
    
    try:
        result = execute(cfg)
        print(f"Execution result: {result}")
        return True
    except Exception as e:
        print(f"Error during execution: {e}")
        return False


if __name__ == "__main__":
    success = test_bc_province_generation()
    if success:
        print("✅ Test passed - BC province generation working")
        sys.exit(0)
    else:
        print("❌ Test failed - issues with BC province generation")
        sys.exit(1)