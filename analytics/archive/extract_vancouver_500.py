#!/usr/bin/env python3
"""Generate and extract 500 Vancouver (BC) patients using synthea_original.

This script follows the lessons in docs/LESSONS_LEARNED_SYNTHEA_CA.md:
- Uses the `synthea_original` codebase (build/libs/synthea-with-dependencies.jar)
- Builds the fat JAR if missing (via the included Gradle wrapper)
- Attempts to run directly with "British Columbia" "Vancouver" and falls back
  to a US model city if the demographics are missing.

Notes:
- Generating 500 patients can take several minutes and requires Java & Gradle.
- For CI or quick checks set --total to a small number or run tests with
  RUN_SYNTHETHEA=1 to enable the full generation test.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parents[2]
SYN_ORIG = ROOT / "synthea_original"
JAR = SYN_ORIG / "build" / "libs" / "synthea-with-dependencies.jar"
PROP = SYN_ORIG / "src" / "main" / "resources" / "synthea.properties"
TEMP_OUT = ROOT / "output"

# Deterministic city distribution for generated patients. Edit here to change
# the target cities and their percentage shares (must sum to 100).
# Format: list of (city_name, percent)
CITY_DISTRIBUTION = [("Surrey", 50), ("New Westminster", 25), ("Coquitlam", 25)]

# Expand to a flat list for deterministic assignment (repeat city name by percent).
CITY_LIST = []
for _city_name, _pct in CITY_DISTRIBUTION:
    CITY_LIST.extend([_city_name] * int(_pct))
if not CITY_LIST:
    CITY_LIST = ["Vancouver"]


def build_jar():
    """Run the Gradle wrapper to create the fat jar if it's missing."""
    gw = SYN_ORIG / "gradlew"
    if not gw.exists():
        raise FileNotFoundError(f"Gradle wrapper not found in {SYN_ORIG}; cannot build jar")
    print("Building synthea fat JAR (this may take a while)...")
    subprocess.check_call([str(gw), "clean", "shadowJar", "-x", "test"], cwd=str(SYN_ORIG))


def run_synthea(patients: int, seed: Optional[int]) -> Path:
    """Run the synthea jar to generate `patients` and return the fhir output dir."""
    if not JAR.exists():
        raise FileNotFoundError(f"JAR not found: {JAR}")

    # clean temp output
    if TEMP_OUT.exists():
        shutil.rmtree(TEMP_OUT)
    TEMP_OUT.mkdir(parents=True, exist_ok=True)

    args = ["-c", str(PROP), "-p", str(patients)]
    if seed is not None:
        args = ["-s", str(seed)] + args

    # primary attempt: British Columbia / Vancouver (synthea_original should be hardened per lessons)
    primary_cmd = ["java", f"-Dexporter.baseDirectory={ROOT}", "-jar", str(JAR), *args, "British Columbia", "Vancouver"]
    fallback_cmd = ["java", f"-Dexporter.baseDirectory={ROOT}", "-jar", str(JAR), *args, "Washington", "Seattle"]

    try:
        print("Running synthea (BC/Vancouver)...")
        subprocess.check_call(primary_cmd, cwd=str(ROOT))
    except subprocess.CalledProcessError as e:
        print("Primary run failed, falling back to Washington/Seattle model (will map to Vancouver later).", file=sys.stderr)
        print("Error:", e, file=sys.stderr)
        subprocess.check_call(fallback_cmd, cwd=str(ROOT))

    return TEMP_OUT / "fhir"


def modify_and_copy(
    fhir_dir: Path,
    out_dir: Path,
    start_index: int = 1,
    postal_prefix: str = "V5",
    upload: bool = False,
    gcs_bucket: Optional[str] = None,
    gcs_prefix: Optional[str] = None,
    delete_local: bool = False,
) -> int:
    """Modify generated FHIR patient bundles to Vancouver addresses and copy into out_dir.

    Returns number of patients written.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    files = sorted([p for p in fhir_dir.glob("*.json") if not p.name.startswith(("practitioner", "hospital"))])
    written = 0
    idx = start_index
    for f in files:
        try:
            data = json.loads(f.read_text())
        except Exception as ex:
            print(f"Skipping unreadable {f}: {ex}")
            continue

        # patch addresses
        postal_code = f"{postal_prefix}{random.randint(1,9)}{random.choice('ABCDEFGHIJKLMNOPQRSTUVWXYZ')}{random.randint(1,9)}"
        # deterministic city assignment from CITY_LIST based on patient index
        city = CITY_LIST[(idx - 1) % len(CITY_LIST)] if CITY_LIST else "Vancouver"
        if "entry" in data:
            for entry in data["entry"]:
                res = entry.get("resource")
                if not res:
                    continue
                if "address" in res:
                    if isinstance(res["address"], list):
                        for addr in res["address"]:
                            addr["city"] = city
                            addr["state"] = "British Columbia"
                            addr["country"] = "CA"
                            addr["postalCode"] = postal_code
                    elif isinstance(res["address"], dict):
                        addr = res["address"]
                        addr["city"] = city
                        addr["state"] = "British Columbia"
                        addr["country"] = "CA"
                        addr["postalCode"] = postal_code

        out_file = out_dir / f"patient_{idx:04d}.json"
        out_file.write_text(json.dumps(data, indent=2))

        # If requested, convert/upload/delete per-patient immediately to reduce local disk usage
        if upload and gcs_bucket:
            nd_name = out_file.with_suffix('.ndjson')
            try:
                # create wrapped NDJSON lines: {"raw": <resource>}
                _convert_json_to_ndjson(out_file, nd_name, wrap=True)
            except Exception as e:
                print(f"Failed to convert {out_file} -> {nd_name}: {e}", file=sys.stderr)
            else:
                try:
                    print(f"Uploading {nd_name.name} (patient {idx}) to gs://{gcs_bucket}/{gcs_prefix or ''}/")
                    sys.stdout.flush()
                    _upload_to_gcs(nd_name, gcs_bucket, gcs_prefix or "")
                    print(f"Uploaded {nd_name.name}")
                except Exception as e:
                    print(f"Failed to upload {nd_name} to GCS: {e}", file=sys.stderr)
                finally:
                    # remove the temporary ndjson file to save space
                    try:
                        nd_name.unlink()
                    except Exception:
                        pass

                if delete_local:
                    try:
                        out_file.unlink()
                    except Exception:
                        pass

                # brief pause to avoid overwhelming environment/GCS
                if upload_delay := getattr(modify_and_copy, '_upload_delay', None):
                    time.sleep(upload_delay)

        idx += 1
        written += 1

    return written


def _convert_json_to_ndjson(json_path: Path, ndjson_path: Path) -> int:
    """Convert a Synthea per-patient JSON bundle into an NDJSON file (one resource per line).

    Returns number of lines written.
    """
    data = json.loads(json_path.read_text())
    count = 0
    with ndjson_path.open("w", encoding="utf-8") as out:
        # If this appears to be a bundle with 'entry' list, write each entry.resource
        if isinstance(data, dict) and "entry" in data and isinstance(data["entry"], list):
            for entry in data["entry"]:
                res = entry.get("resource")
                if res is None:
                    continue
                out.write(json.dumps(res, separators=(",", ":"), ensure_ascii=False))
                out.write("\n")
                count += 1
        else:
            # otherwise write the whole object as one line
            out.write(json.dumps(data, separators=(",", ":"), ensure_ascii=False))
            out.write("\n")
            count = 1
    return count


def _upload_to_gcs(local_path: Path, bucket: str, prefix: str) -> None:
    dest_prefix = prefix.strip("/") if prefix else ""
    if dest_prefix:
        dest = f"gs://{bucket}/{dest_prefix}/{local_path.name}"
    else:
        dest = f"gs://{bucket}/{local_path.name}"
    # Use gsutil to copy; let subprocess surface any errors
    subprocess.check_call(["gsutil", "cp", str(local_path), dest])


def main(argv=None):
    parser = argparse.ArgumentParser(description="Generate and extract Vancouver patients using synthea_original")
    parser.add_argument("--total", type=int, default=500)
    parser.add_argument("--batch-size", type=int, default=50)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--out-dir", type=str, default="analytics/test_output")
    parser.add_argument("--build-if-missing", action="store_true", help="Run Gradle to build the JAR if missing")
    parser.add_argument("--upload", action="store_true", help="Convert per-patient JSON to NDJSON and upload to GCS")
    parser.add_argument("--gcs-bucket", type=str, default="synthea-raw-hospigen", help="GCS bucket to upload per-patient NDJSON files to")
    parser.add_argument("--gcs-prefix", type=str, default="patients", help="GCS prefix (folder) under the bucket to upload files to")
    parser.add_argument("--delete-local", action="store_true", help="Delete per-patient JSON files locally after successful upload")
    args = parser.parse_args(argv)

    out_dir = ROOT / args.out_dir
    # overwrite
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    if not JAR.exists():
        if args.build_if_missing:
            build_jar()
        else:
            raise FileNotFoundError(f"synthea jar not found at {JAR}; set --build-if-missing to build it")

    total = args.total
    batch = args.batch_size
    seed = args.seed

    generated_total = 0
    batch_idx = 0
    patient_counter = 1

    while generated_total < total:
        this_count = min(batch, total - generated_total)
        print(f"\n=== Batch {batch_idx+1}: generating {this_count} patients ===")
        try:
            fhir_dir = run_synthea(this_count, seed + batch_idx if seed is not None else None)
        except Exception as e:
            print(f"Synthea run failed for batch {batch_idx+1}: {e}", file=sys.stderr)
            raise

        if not fhir_dir.exists():
            raise RuntimeError(f"Expected FHIR output directory not found: {fhir_dir}")

        written = modify_and_copy(
            fhir_dir,
            out_dir,
            start_index=patient_counter,
            upload=args.upload,
            gcs_bucket=args.gcs_bucket,
            gcs_prefix=args.gcs_prefix,
            delete_local=args.delete_local,
        )
        generated_total += written
        patient_counter += written

        # cleanup temp output
        try:
            shutil.rmtree(TEMP_OUT)
        except Exception:
            pass

        batch_idx += 1
        time.sleep(0.1)

    summary = {
        "requested": total,
        "generated": generated_total,
        "output_dir": str(out_dir)
    }
    (out_dir / "vancouver_generation_summary.json").write_text(json.dumps(summary, indent=2))
    print(f"\n✓ Completed: wrote {generated_total} patients to {out_dir}")

    # Optional: convert per-patient JSON files into NDJSON (one resource per line) and upload to GCS
    if args.upload:
        print(f"Converting per-patient JSON files in {out_dir} to NDJSON and uploading to gs://{args.gcs_bucket}/{args.gcs_prefix}/")
        json_files = sorted([p for p in out_dir.glob("patient_*.json")])
        if not json_files:
            print("No per-patient JSON files found to upload.")
            return
        for jf in json_files:
            nd_name = jf.with_suffix('.ndjson').name
            nd_local = out_dir / nd_name
            try:
                lines = _convert_json_to_ndjson(jf, nd_local)
            except Exception as e:
                print(f"Failed to convert {jf} -> {nd_local}: {e}", file=sys.stderr)
                continue
            try:
                _upload_to_gcs(nd_local, args.gcs_bucket, args.gcs_prefix)
            except Exception as e:
                print(f"Failed to upload {nd_local} to GCS: {e}", file=sys.stderr)
                continue
            print(f"Uploaded {nd_local.name} ({lines} lines) to gs://{args.gcs_bucket}/{args.gcs_prefix}/")


if __name__ == "__main__":
    main()
