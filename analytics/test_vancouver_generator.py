#!/usr/bin/env python3
"""
Test the Vancouver patient generator with a small batch (20 patients)
to verify it works correctly before running the full 1,000.
"""

import sys
from pathlib import Path

# Add analytics directory to path
analytics_dir = Path(__file__).parent
sys.path.append(str(analytics_dir))

from generate_vancouver_patients import VancouverPatientConfig, generate_vancouver_patients

def test_small_batch():
    """Test with 20 patients"""
    print("=== Testing Vancouver Patient Generator (20 patients) ===\n")
    
    # Temporarily modify the generator for small test
    original_generate = generate_vancouver_patients
    
    def test_generate():
        config = VancouverPatientConfig(total_count=20, seed=42)
        
        from generate_vancouver_patients import (
            ensure_synthea_jar, ensure_synthea_config, process_and_organize_output,
            OUT_DIR
        )
        
        print("Testing with 20 patients across Vancouver area cities...")
        print(f"Batch distribution:")
        for batch in config.batches:
            print(f"  {batch['vancouver_city']}: {batch['count']} patients (using {batch['us_model_city']} demographics)")
        print()
        
        # Setup
        ensure_synthea_jar()
        ensure_synthea_config()
        
        # Generate and process patients
        results = process_and_organize_output(config)
        
        # Save test summary
        summary_file = OUT_DIR / "test_generation_summary.json"
        import json
        with open(summary_file, 'w') as f:
            json.dump(results, f, indent=2)
        
        return results
    
    try:
        results = test_generate()
        
        print(f"\n=== Test Complete ===")
        print(f"✓ Generated {results['total_patients_generated']} patient JSON files")
        print(f"✓ Output directory: {results['output_directory']}")
        
        # Show breakdown
        print(f"\nTest results by city:")
        for batch in results['batches_processed']:
            print(f"  {batch['vancouver_city']}: {batch['files_generated']} patients")
        
        # Show a sample file
        if results['vancouver_patients']:
            sample = results['vancouver_patients'][0]
            sample_path = Path(results['output_directory']) / sample['file']
            if sample_path.exists():
                print(f"\nSample file: {sample['file']}")
                print(f"Location info preview:")
                with open(sample_path, 'r') as f:
                    import json
                    data = json.load(f)
                    # Find patient resource
                    for entry in data.get('entry', []):
                        resource = entry.get('resource', {})
                        if resource.get('resourceType') == 'Patient':
                            addresses = resource.get('address', [])
                            if addresses:
                                addr = addresses[0]
                                print(f"  City: {addr.get('city', 'N/A')}")
                                print(f"  State/Province: {addr.get('state', 'N/A')}")
                                print(f"  Country: {addr.get('country', 'N/A')}")
                                print(f"  Postal Code: {addr.get('postalCode', 'N/A')}")
                            break
        
        print(f"\n🎉 Test successful! Ready for full 1,000 patient generation.")
        return True
        
    except Exception as e:
        print(f"❌ Test failed: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    success = test_small_batch()
    if not success:
        sys.exit(1)