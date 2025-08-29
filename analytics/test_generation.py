#!/usr/bin/env python3
"""
Test script to generate a small batch of patients (10) to verify the system works
before running the full 1,000 patient generation.
"""

import os
import json
import shlex
import subprocess
import urllib.request
from pathlib import Path

# Directory structure - relative to repo root
ROOT = Path(__file__).resolve().parents[1]
SYN_DIR = ROOT / "synthea"
DL_DIR = SYN_DIR / "downloads"
CFG_DIR = SYN_DIR / "config"
OUT_DIR = ROOT / "analytics" / "output"

JAR = DL_DIR / "synthea-with-dependencies.jar"
PROP_FILE = CFG_DIR / "synthea-canada.properties"

def ensure_synthea_jar():
    """Download Synthea JAR if not present"""
    if JAR.exists():
        print(f"Synthea JAR already exists: {JAR}")
        return
        
    JAR.parent.mkdir(parents=True, exist_ok=True)
    version = "v3.0.0"
    jar_name = "synthea-with-dependencies.jar"
    url = f"https://github.com/synthetichealth/synthea/releases/download/{version}/{jar_name}"
    
    print(f"Downloading Synthea JAR from {url} to {JAR}...")
    try:
        urllib.request.urlretrieve(url, str(JAR))
        print(f"Successfully downloaded Synthea JAR to {JAR}")
    except Exception as e:
        raise RuntimeError(f"Failed to download Synthea JAR: {e}")

def clone_synthea_repo():
    """Clone Synthea repository if not present"""
    if SYN_DIR.exists():
        print(f"Synthea directory already exists: {SYN_DIR}")
        return
        
    print(f"Cloning Synthea repository to {SYN_DIR}...")
    try:
        subprocess.check_call([
            "git", "clone", 
            "https://github.com/synthetichealth/synthea.git",
            str(SYN_DIR)
        ], cwd=str(ROOT))
        print(f"Successfully cloned Synthea to {SYN_DIR}")
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Failed to clone Synthea repository: {e}")

def ensure_canada_config():
    """Ensure Synthea Canada configuration exists"""
    CFG_DIR.mkdir(parents=True, exist_ok=True)
    
    if PROP_FILE.exists():
        print(f"Canada config already exists: {PROP_FILE}")
        return
    
    # Create basic Canada configuration
    config_content = """# Synthea Canada Configuration
exporter.fhir.export = true
exporter.csv.export = false
exporter.text.export = false
exporter.cdw.export = false
exporter.ccda.export = false

# Use Canadian geography
generate.geography.international = true
generate.geography.country_code = CA

# Patient count and demographics
generate.default_population = 10

# Reduce verbosity
exporter.baseDirectory = ./output
"""
    
    with open(PROP_FILE, 'w') as f:
        f.write(config_content)
    print(f"Created Canada configuration: {PROP_FILE}")

def test_generation():
    """Test patient generation with a small batch"""
    print("=== Testing Patient Generation (10 patients) ===")
    
    # Setup
    ensure_synthea_jar()
    clone_synthea_repo()
    ensure_canada_config()
    
    # Run Synthea for Vancouver with 10 patients
    java_opts = [
        f"-Dexporter.baseDirectory={SYN_DIR / 'output'}",
        "-Dgenerate.geography.country_code=CA",
        "-Dgenerate.geography.international=true"
    ]
    
    args = [
        "-c", str(PROP_FILE),
        "-p", "10",
        "-s", "42",  # Seed for reproducibility
        "British Columbia", "Vancouver"
    ]
    
    cmd = [
        "java",
        *java_opts,
        "-jar", str(JAR),
        *args,
    ]
    
    print("Running:", " ".join(shlex.quote(x) for x in cmd))
    
    try:
        subprocess.check_call(cmd, cwd=str(ROOT))
        print("✅ Patient generation successful!")
        
        # Check output
        fhir_dir = SYN_DIR / "output" / "fhir"
        if fhir_dir.exists():
            json_files = list(fhir_dir.glob("*.json"))
            print(f"✅ Found {len(json_files)} JSON files in {fhir_dir}")
            
            # Copy first few files to analytics/output for inspection
            OUT_DIR.mkdir(parents=True, exist_ok=True)
            for i, json_file in enumerate(json_files[:3]):
                target_path = OUT_DIR / f"test_patient_{i+1}.json"
                with open(json_file, 'r') as src, open(target_path, 'w') as dst:
                    content = json.load(src)
                    json.dump(content, dst, indent=2)
                print(f"✅ Copied sample file: {target_path}")
                
            return True
        else:
            print("❌ No FHIR output directory found")
            return False
            
    except subprocess.CalledProcessError as e:
        print(f"❌ Patient generation failed: {e}")
        return False

if __name__ == "__main__":
    success = test_generation()
    if success:
        print("\n🎉 Test successful! Ready to generate 1,000 patients.")
    else:
        print("\n❌ Test failed. Please check the error messages above.")