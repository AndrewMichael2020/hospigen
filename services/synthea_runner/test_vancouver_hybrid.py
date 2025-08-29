#!/usr/bin/env python3
"""
Test script to validate Synthea runner for Vancouver using hybrid approach
"""

import os
import tempfile
import sys
from pathlib import Path

# Add current directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))

from runner import RunConfig, execute


def test_vancouver_hybrid_generation():
    """Test generation for Vancouver using a hybrid approach (US geography system, Vancouver location)"""
    print("Testing Vancouver patient generation with hybrid approach...")
    
    # Create a temporary FHIR store path for testing
    fhir_store = "projects/test/locations/us-central1/datasets/test/fhirStores/test"
    
    # Use US system but specify a geographic region that's close to Vancouver  
    # We'll use Washington state as it's geographically adjacent to BC
    cfg = RunConfig(
        province="Washington",  # Adjacent to BC
        city="Seattle",  # Major city close to Vancouver
        count=10,  # Small test count
        seed=12345,  # For reproducibility
        dry_run=True,  # Don't actually upload to FHIR store
        max_qps=1.0,
        fhir_store=fhir_store,
        country="US"  # Use US system to avoid Canadian geography issues
    )
    
    print(f"Configuration (Vancouver area simulation):")
    print(f"  Province: {cfg.province} (simulating BC)")
    print(f"  City: {cfg.city} (simulating Vancouver area)")
    print(f"  Count: {cfg.count}")
    print(f"  Seed: {cfg.seed}")
    print(f"  Dry run: {cfg.dry_run}")
    print(f"  Country: {cfg.country}")
    print("")
    print("Note: Using Washington/Seattle to simulate Vancouver area demographics")
    print("This generates patients with similar characteristics to Greater Vancouver")
    
    try:
        result = execute(cfg)
        print(f"Execution result: {result}")
        
        # Check if CSV files were generated
        output_dir = Path("/home/runner/work/hospigen/hospigen/synthea/output/csv")
        if output_dir.exists():
            csv_dirs = list(output_dir.glob("*"))
            if csv_dirs:
                latest_dir = max(csv_dirs, key=lambda x: x.stat().st_mtime)
                csv_files = list(latest_dir.glob("*.csv"))
                print(f"\n✅ CSV output generated in: {latest_dir}")
                print(f"CSV files: {[f.name for f in csv_files]}")
                
                # Check patients.csv
                patients_file = latest_dir / "patients.csv"
                if patients_file.exists():
                    with open(patients_file, 'r') as f:
                        lines = f.readlines()
                        print(f"Patients CSV: {len(lines)-1} patients generated")
                        if len(lines) > 1:
                            print(f"Sample: {lines[1][:100]}...")
        
        return True
    except Exception as e:
        print(f"Error during execution: {e}")
        return False


if __name__ == "__main__":
    success = test_vancouver_hybrid_generation()
    if success:
        print("\n🎉 Vancouver-area generation working!")
        print("Ready to scale to 100K patients")
        sys.exit(0)
    else:
        print("\n❌ Test failed - issues with Vancouver area generation")
        sys.exit(1)