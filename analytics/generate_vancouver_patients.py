#!/usr/bin/env python3
"""
Generate 1,000 synthetic patients for the Greater Vancouver Area, British Columbia.
This script uses Synthea to generate realistic patient data and then modifies the 
location information to represent Vancouver area cities.
"""

import os
import json
import shlex
import subprocess
import urllib.request
import random
from pathlib import Path
from typing import Dict, Any, List, Optional

# Directory structure - relative to repo root
ROOT = Path(__file__).resolve().parents[1]  # One level up from analytics/
SYN_DIR = ROOT / "synthea"
DL_DIR = SYN_DIR / "downloads"
CFG_DIR = SYN_DIR / "config"
OUT_DIR = ROOT / "analytics" / "output"  # Our target output directory
TEMP_OUT_DIR = ROOT / "output"  # Synthea's actual output location

JAR = DL_DIR / "synthea-with-dependencies.jar"
PROP_FILE = CFG_DIR / "synthea-vancouver.properties"

# Greater Vancouver Area cities and their postal code prefixes
VANCOUVER_CITIES = {
    "Vancouver": {"postal_prefix": "V5", "population_weight": 0.4},
    "Burnaby": {"postal_prefix": "V3", "population_weight": 0.15}, 
    "Surrey": {"postal_prefix": "V3", "population_weight": 0.25},
    "Richmond": {"postal_prefix": "V6", "population_weight": 0.2}
}

# Washington state cities we'll use as demographic models (similar climate/demographics to Vancouver)
US_MODEL_CITIES = ["Seattle", "Bellevue", "Tacoma", "Spokane"]

class VancouverPatientConfig:
    """Configuration for Vancouver patient generation"""
    def __init__(self, total_count: int = 1000, seed: Optional[int] = None):
        self.total_count = total_count
        self.seed = seed
        self.batches = self._create_batches()
        
    def _create_batches(self) -> List[Dict[str, Any]]:
        """Create generation batches for different cities"""
        batches = []
        remaining = self.total_count
        
        for i, (vancouver_city, config) in enumerate(VANCOUVER_CITIES.items()):
            # Calculate patients for this city based on population weight
            if i == len(VANCOUVER_CITIES) - 1:  # Last city gets remainder
                count = remaining
            else:
                count = int(self.total_count * config["population_weight"])
                remaining -= count
            
            # Pick a US model city for demographics
            us_city = US_MODEL_CITIES[i % len(US_MODEL_CITIES)]
            
            batches.append({
                "vancouver_city": vancouver_city,
                "us_model_city": us_city,
                "count": count,
                "postal_prefix": config["postal_prefix"],
                "seed": self.seed + i if self.seed else None
            })
            
        return batches


def ensure_synthea_jar() -> None:
    """Download Synthea JAR if not present"""
    if JAR.exists():
        print(f"✓ Synthea JAR exists: {JAR}")
        return
        
    JAR.parent.mkdir(parents=True, exist_ok=True)
    version = "v3.0.0"
    jar_name = "synthea-with-dependencies.jar"
    url = f"https://github.com/synthetichealth/synthea/releases/download/{version}/{jar_name}"
    
    print(f"Downloading Synthea JAR from {url}...")
    try:
        urllib.request.urlretrieve(url, str(JAR))
        print(f"✓ Downloaded Synthea JAR")
    except Exception as e:
        raise RuntimeError(f"Failed to download Synthea JAR: {e}")


def ensure_synthea_config() -> None:
    """Create Synthea configuration optimized for our use case"""
    CFG_DIR.mkdir(parents=True, exist_ok=True)
    
    config_content = """# Synthea Configuration for Vancouver Patient Generation
exporter.fhir.export = true
exporter.csv.export = false
exporter.text.export = false
exporter.cdw.export = false
exporter.ccda.export = false

# Performance settings
generate.default_population = 1000
generate.log_patients.detail = false

# Output settings  
exporter.baseDirectory = ./output
"""
    
    with open(PROP_FILE, 'w') as f:
        f.write(config_content)
    print(f"✓ Created configuration: {PROP_FILE}")


def run_synthea_batch(batch: Dict[str, Any]) -> Path:
    """Run Synthea for a batch of patients"""
    print(f"\nGenerating {batch['count']} patients using {batch['us_model_city']} demographics...")
    
    # Synthea command arguments
    args = [
        "-c", str(PROP_FILE),
        "-p", str(batch['count']),
    ]
    
    if batch['seed'] is not None:
        args += ["-s", str(batch['seed'])]
    
    # Use Washington state and model city for demographics
    args += ["Washington", batch['us_model_city']]
    
    # Full command
    cmd = [
        "java",
        f"-Dexporter.baseDirectory={ROOT}",
        "-jar", str(JAR),
        *args,
    ]
    
    print("Running:", " ".join(shlex.quote(x) for x in cmd))
    
    try:
        # Clean output directory first
        if TEMP_OUT_DIR.exists():
            import shutil
            shutil.rmtree(TEMP_OUT_DIR)
            
        subprocess.check_call(cmd, cwd=str(ROOT))
        return TEMP_OUT_DIR / "fhir"
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Synthea failed for batch {batch}: {e}")


def modify_patient_location(patient_data: Dict[str, Any], vancouver_city: str, postal_prefix: str) -> Dict[str, Any]:
    """Modify patient bundle to use Vancouver location data"""
    modified = patient_data.copy()
    
    # Generate a realistic Vancouver postal code
    postal_code = f"{postal_prefix}{random.randint(1,9)}{random.choice('ABCDEFGHIJKLMNOPQRSTUVWXYZ')}{random.randint(1,9)}"
    
    # Modify all entries in the bundle
    if "entry" in modified:
        for entry in modified["entry"]:
            if "resource" in entry:
                resource = entry["resource"]
                
                # Update Patient resources
                if resource.get("resourceType") == "Patient":
                    if "address" in resource:
                        for address in resource["address"]:
                            address["city"] = vancouver_city
                            address["state"] = "British Columbia"
                            address["country"] = "CA"
                            address["postalCode"] = postal_code
                
                # Update addresses in other resources (Encounter, Organization, etc.)
                if "address" in resource:
                    if isinstance(resource["address"], list):
                        for address in resource["address"]:
                            address["city"] = vancouver_city
                            address["state"] = "British Columbia"
                            address["country"] = "CA"
                    elif isinstance(resource["address"], dict):
                        address = resource["address"]
                        address["city"] = vancouver_city
                        address["state"] = "British Columbia"
                        address["country"] = "CA"
                
                # Update Organization/Provider locations
                if resource.get("resourceType") in ["Organization", "Practitioner"]:
                    if "address" in resource:
                        for address in resource["address"]:
                            address["city"] = vancouver_city
                            address["state"] = "British Columbia"
                            address["country"] = "CA"
    
    return modified


def process_and_organize_output(config: VancouverPatientConfig) -> Dict[str, Any]:
    """Process all generated files and organize them in analytics/output"""
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    
    results = {
        "total_patients_requested": config.total_count,
        "batches_processed": [],
        "output_directory": str(OUT_DIR),
        "vancouver_patients": []
    }
    
    patient_count = 0
    
    for batch in config.batches:
        print(f"\nProcessing batch for {batch['vancouver_city']}...")
        
        # Run Synthea for this batch
        fhir_output_dir = run_synthea_batch(batch)
        
        # Process the generated files
        if fhir_output_dir.exists():
            json_files = list(fhir_output_dir.glob("*.json"))
            patient_files = [f for f in json_files if not f.name.startswith(('practitioner', 'hospital'))]
            
            batch_results = {
                "vancouver_city": batch['vancouver_city'],
                "us_model_city": batch['us_model_city'],
                "requested_count": batch['count'],
                "files_generated": len(patient_files),
                "files": []
            }
            
            for json_file in patient_files:
                patient_count += 1
                target_name = f"vancouver_patient_{patient_count:04d}_{batch['vancouver_city'].lower()}.json"
                target_path = OUT_DIR / target_name
                
                # Load, modify, and save the patient data
                with open(json_file, 'r') as f:
                    patient_data = json.load(f)
                
                # Modify location data to Vancouver
                modified_data = modify_patient_location(
                    patient_data, 
                    batch['vancouver_city'], 
                    batch['postal_prefix']
                )
                
                # Save to analytics output
                with open(target_path, 'w') as f:
                    json.dump(modified_data, f, indent=2)
                
                batch_results["files"].append(target_name)
                results["vancouver_patients"].append({
                    "file": target_name,
                    "city": batch['vancouver_city'],
                    "patient_number": patient_count
                })
            
            results["batches_processed"].append(batch_results)
            print(f"✓ Processed {len(patient_files)} patients for {batch['vancouver_city']}")
    
    results["total_patients_generated"] = patient_count
    return results


def generate_vancouver_patients() -> Dict[str, Any]:
    """Main function to generate Vancouver area patients"""
    print("=== Vancouver Patient Generator ===")
    print("Generating 1,000 synthetic patients for Greater Vancouver Area, BC")
    print("Cities: Vancouver, Burnaby, Surrey, Richmond")
    print("Using Washington state demographics as a model\n")
    
    config = VancouverPatientConfig(total_count=1000, seed=42)
    
    # Setup
    ensure_synthea_jar()
    ensure_synthea_config()
    
    # Generate and process patients
    results = process_and_organize_output(config)
    
    # Save generation summary
    summary_file = OUT_DIR / "vancouver_generation_summary.json"
    with open(summary_file, 'w') as f:
        json.dump(results, f, indent=2)
    
    return results


if __name__ == "__main__":
    try:
        print("Starting Vancouver patient data generation...\n")
        results = generate_vancouver_patients()
        
        print(f"\n=== Generation Complete ===")
        print(f"✓ Generated {results['total_patients_generated']} patient JSON files")
        print(f"✓ Output directory: {results['output_directory']}")
        print(f"✓ Summary: {OUT_DIR}/vancouver_generation_summary.json")
        
        # Show breakdown by city
        print(f"\nBreakdown by Vancouver area city:")
        for batch in results['batches_processed']:
            print(f"  {batch['vancouver_city']}: {batch['files_generated']} patients")
        
        print(f"\nPatient files are ready for analysis!")
        
    except Exception as e:
        print(f"❌ Error generating patients: {e}")
        raise