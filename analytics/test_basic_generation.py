#!/usr/bin/env python3
"""
Test script using US geography to verify Synthea works, then adapt for Canada.
"""

import os
import json
import shlex
import subprocess
from pathlib import Path

# Directory structure
ROOT = Path(__file__).resolve().parents[1]
SYN_DIR = ROOT / "synthea"
DL_DIR = SYN_DIR / "downloads"
CFG_DIR = SYN_DIR / "config"
OUT_DIR = ROOT / "analytics" / "output"

JAR = DL_DIR / "synthea-with-dependencies.jar"
PROP_FILE = CFG_DIR / "synthea-test.properties"

def create_basic_config():
    """Create basic Synthea configuration"""
    CFG_DIR.mkdir(parents=True, exist_ok=True)
    
    config_content = """# Basic Synthea Configuration
exporter.fhir.export = true
exporter.csv.export = false
exporter.text.export = false
exporter.cdw.export = false
exporter.ccda.export = false

# Patient count
generate.default_population = 10

# Output directory
exporter.baseDirectory = ./output
"""
    
    with open(PROP_FILE, 'w') as f:
        f.write(config_content)
    print(f"Created basic configuration: {PROP_FILE}")

def test_us_generation():
    """Test with US geography first"""
    print("=== Testing US Patient Generation (10 patients) ===")
    
    create_basic_config()
    
    # Run Synthea for Washington state (similar climate to BC)
    args = [
        "-c", str(PROP_FILE),
        "-p", "10",
        "-s", "42",
        "Washington", "Seattle"
    ]
    
    cmd = [
        "java",
        f"-Dexporter.baseDirectory={SYN_DIR / 'output'}",
        "-jar", str(JAR),
        *args,
    ]
    
    print("Running:", " ".join(shlex.quote(x) for x in cmd))
    
    try:
        subprocess.check_call(cmd, cwd=str(ROOT))
        print("✅ US patient generation successful!")
        
        # Check output
        fhir_dir = SYN_DIR / "output" / "fhir"
        if fhir_dir.exists():
            json_files = list(fhir_dir.glob("*.json"))
            print(f"✅ Found {len(json_files)} JSON files in {fhir_dir}")
            
            # Copy a sample file for inspection
            OUT_DIR.mkdir(parents=True, exist_ok=True)
            if json_files:
                sample_file = json_files[0]
                target_path = OUT_DIR / "us_sample_patient.json"
                with open(sample_file, 'r') as src, open(target_path, 'w') as dst:
                    content = json.load(src)
                    json.dump(content, dst, indent=2)
                print(f"✅ Copied sample file: {target_path}")
                
                # Inspect the structure
                print(f"✅ Sample patient structure:")
                if 'resourceType' in content:
                    print(f"   Resource Type: {content['resourceType']}")
                if 'entry' in content:
                    print(f"   Entries: {len(content['entry'])}")
                    if content['entry']:
                        first_entry = content['entry'][0]
                        if 'resource' in first_entry:
                            resource = first_entry['resource']
                            print(f"   First Resource Type: {resource.get('resourceType', 'Unknown')}")
                
            return True
        else:
            print("❌ No FHIR output directory found")
            return False
            
    except subprocess.CalledProcessError as e:
        print(f"❌ Patient generation failed: {e}")
        return False

def test_province_only():
    """Test British Columbia without city"""
    print("\n=== Testing BC Province Only (no city) ===")
    
    # Try with CA settings but no city
    args = [
        "-c", str(PROP_FILE),
        "-p", "5",
        "-s", "43"
    ]
    
    cmd = [
        "java",
        f"-Dexporter.baseDirectory={SYN_DIR / 'output'}",
        "-Dgenerate.geography.country_code=CA",
        "-jar", str(JAR),
        *args,
    ]
    
    print("Running:", " ".join(shlex.quote(x) for x in cmd))
    
    try:
        subprocess.check_call(cmd, cwd=str(ROOT))
        print("✅ CA patient generation successful!")
        return True
    except subprocess.CalledProcessError as e:
        print(f"❌ CA generation failed: {e}")
        return False

if __name__ == "__main__":
    # Test US first to ensure Synthea works
    us_success = test_us_generation()
    
    if us_success:
        print("\n🎉 US generation works! Now testing Canada...")
        ca_success = test_province_only()
        
        if ca_success:
            print("\n🎉 Canada generation also works!")
        else:
            print("\n⚠️  Canada generation failed, but US works. Will use US data for now.")
    else:
        print("\n❌ Basic Synthea generation failed. Check setup.")