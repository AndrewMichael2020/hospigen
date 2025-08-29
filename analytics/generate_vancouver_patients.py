#!/usr/bin/env python3
"""
Generate 1,000 synthetic patients for the Greater Vancouver Area, British Columbia.
This script adapts the existing Synthea runner logic to generate patients locally
without uploading to FHIR stores, placing the JSON output in analytics/output/
"""

import os
import json
import shlex
import subprocess
import urllib.request
from pathlib import Path
from typing import Dict, Any, List, Optional

# Directory structure - relative to repo root
ROOT = Path(__file__).resolve().parents[1]  # One level up from analytics/
SYN_DIR = ROOT / "synthea"
DL_DIR = SYN_DIR / "downloads"
RES_DIR = SYN_DIR / "src" / "main" / "resources"  # Standard Synthea location
CFG_DIR = SYN_DIR / "config"
OUT_DIR = ROOT / "analytics" / "output"  # Our target output directory

JAR = DL_DIR / "synthea-with-dependencies.jar"
PROP_FILE = CFG_DIR / "synthea-canada.properties"

# Greater Vancouver Area cities to generate patients for
VANCOUVER_CITIES = [
    "Vancouver",
    "Burnaby", 
    "Surrey",
    "Richmond"
]

class PatientGenConfig:
    """Configuration for patient generation"""
    def __init__(self,
                 province: str = "British Columbia",
                 cities: List[str] = None,
                 total_count: int = 1000,
                 seed: Optional[int] = None):
        self.province = province
        self.cities = cities or VANCOUVER_CITIES
        self.total_count = total_count
        self.seed = seed
        self.patients_per_city = total_count // len(self.cities)
        self.remainder = total_count % len(self.cities)


def ensure_synthea_jar() -> None:
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
    
    if not JAR.exists():
        raise FileNotFoundError(f"Synthea JAR not found after download: {JAR}")


def clone_synthea_repo() -> None:
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


def ensure_canada_config() -> None:
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

# Demographics
generate.demographics.default_file = demographics_ca.csv
generate.providers.default_file = providers_ca.csv
generate.payers.default_file = payers_ca.csv

# Patient count and demographics
generate.default_population = 1000

# Reduce verbosity
exporter.baseDirectory = ./output
"""
    
    with open(PROP_FILE, 'w') as f:
        f.write(config_content)
    print(f"Created Canada configuration: {PROP_FILE}")


def run_synthea_for_city(city: str, count: int, seed: Optional[int] = None) -> Path:
    """Run Synthea for a specific city and return output directory"""
    print(f"\nGenerating {count} patients for {city}, British Columbia...")
    
    # Create temporary output directory for this city
    city_out_dir = SYN_DIR / "output" / "fhir"
    
    # Java options for Canadian geography
    java_opts = [
        f"-Dexporter.baseDirectory={SYN_DIR / 'output'}",
        "-Dgenerate.geography.country_code=CA",
        "-Dgenerate.geography.international=true"
    ]
    
    # Check if we have local Canadian geography
    geo_dir = RES_DIR / 'geography'
    if geo_dir.exists():
        java_opts.append(f"-Dgenerate.geography.directory={geo_dir}")
        print(f"Using local geography dir: {geo_dir}")
    else:
        print("Using built-in Synthea geography for Canada")
    
    # Synthea command arguments
    args = [
        "-c", str(PROP_FILE),
        "-p", str(count),
    ]
    
    if seed is not None:
        args += ["-s", str(seed)]
    
    # Add province and city
    args += ["British Columbia", city]
    
    # Full command
    cmd = [
        "java",
        *java_opts,
        "-jar", str(JAR),
        *args,
    ]
    
    print("Running:", " ".join(shlex.quote(x) for x in cmd))
    
    try:
        subprocess.check_call(cmd, cwd=str(ROOT))
        return city_out_dir
    except subprocess.CalledProcessError as e:
        print(f"Synthea failed for {city} (exit {e.returncode}). Retrying with province only...")
        
        # Retry with province only
        retry_args = [
            "java",
            *java_opts,
            "-jar", str(JAR),
            "-c", str(PROP_FILE),
            "-p", str(count)
        ]
        if seed is not None:
            retry_args += ["-s", str(seed)]
        retry_args += ["British Columbia"]
        
        print("Running (fallback):", " ".join(shlex.quote(x) for x in retry_args))
        subprocess.check_call(retry_args, cwd=str(ROOT))
        return city_out_dir


def collect_and_organize_output(config: PatientGenConfig) -> Dict[str, Any]:
    """Collect all generated JSON files and organize them in analytics/output"""
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    
    total_files = 0
    results = {
        "total_patients": config.total_count,
        "cities_generated": [],
        "output_directory": str(OUT_DIR),
        "json_files": []
    }
    
    # Find all JSON files in Synthea output
    synthea_output = SYN_DIR / "output" / "fhir"
    if synthea_output.exists():
        json_files = list(synthea_output.glob("*.json"))
        
        for i, json_file in enumerate(json_files):
            # Copy to analytics output with organized naming
            target_name = f"patient_{i+1:04d}.json"
            target_path = OUT_DIR / target_name
            
            # Read and copy the JSON file
            with open(json_file, 'r') as src:
                content = json.load(src)
            
            with open(target_path, 'w') as dst:
                json.dump(content, dst, indent=2)
            
            results["json_files"].append(target_name)
            total_files += 1
    
    results["total_files_generated"] = total_files
    print(f"\nGenerated {total_files} patient JSON files in {OUT_DIR}")
    
    return results


def generate_vancouver_patients() -> Dict[str, Any]:
    """Main function to generate Vancouver area patients"""
    print("=== Generating 1,000 Patients for Greater Vancouver Area ===")
    
    config = PatientGenConfig(
        province="British Columbia",
        cities=VANCOUVER_CITIES,
        total_count=1000,
        seed=42  # For reproducible results
    )
    
    print(f"Configuration:")
    print(f"  Province: {config.province}")
    print(f"  Cities: {', '.join(config.cities)}")
    print(f"  Total patients: {config.total_count}")
    print(f"  Patients per city: ~{config.patients_per_city}")
    
    # Setup
    ensure_synthea_jar()
    clone_synthea_repo()
    ensure_canada_config()
    
    # Generate patients for each city
    for i, city in enumerate(config.cities):
        count = config.patients_per_city
        # Add remainder to first city
        if i == 0:
            count += config.remainder
            
        seed = config.seed + i if config.seed else None
        run_synthea_for_city(city, count, seed)
    
    # Collect and organize results
    return collect_and_organize_output(config)


if __name__ == "__main__":
    try:
        results = generate_vancouver_patients()
        
        # Save generation summary
        summary_file = OUT_DIR / "generation_summary.json"
        with open(summary_file, 'w') as f:
            json.dump(results, f, indent=2)
        
        print(f"\n=== Generation Complete ===")
        print(f"Generated {results['total_files_generated']} patient JSON files")
        print(f"Output directory: {results['output_directory']}")
        print(f"Summary saved to: {summary_file}")
        
    except Exception as e:
        print(f"Error generating patients: {e}")
        raise