#!/usr/bin/env python3
"""Generate patients with city distribution and upload in batches to BigQuery via GCS.

Usage: python analytics/generate_and_upload_bq.py --bucket my-bucket --dataset mydataset --table mytable

The script will generate 10_000 patients by default, in batches of 100, distributed across
Surrey (50%), New Westminster (20%), Langley (30% combined assumed from duplicate entries).

Requirements: java, gcloud/gsutil, bq (Cloud SDK). The script calls the local synthea JAR and uses
gsutil + bq commands to push data. It deletes the local batch file after successful upload.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, Optional

ROOT = Path(__file__).resolve().parents[1]
SYN_ORIG = ROOT / "synthea_original"
JAR = SYN_ORIG / "build" / "libs" / "synthea-with-dependencies.jar"
PROP = SYN_ORIG / "src" / "main" / "resources" / "synthea.properties"
TEMP_OUT = ROOT / "output"


def require_cmd(name: str):
    if shutil.which(name) is None:
        raise RuntimeError(f"Required command not found on PATH: {name}")


def build_jar():
    gw = SYN_ORIG / "gradlew"
    if not gw.exists():
        raise FileNotFoundError(f"Gradle wrapper not found in {SYN_ORIG}; cannot build jar")
    print("Building synthea fat JAR (this may take a while)...")
    subprocess.check_call([str(gw), "clean", "shadowJar", "-x", "test"], cwd=str(SYN_ORIG))


def run_synthea(patients: int, city: str, seed: Optional[int]) -> Path:
    if not JAR.exists():
        raise FileNotFoundError(f"JAR not found: {JAR}")

    # clean temp output
    if TEMP_OUT.exists():
        shutil.rmtree(TEMP_OUT)
    TEMP_OUT.mkdir(parents=True, exist_ok=True)

    args = ["-c", str(PROP), "-p", str(patients)]
    if seed is not None:
        args = ["-s", str(seed)] + args

    primary_cmd = ["java", f"-Dexporter.baseDirectory={ROOT}", "-jar", str(JAR), *args, "British Columbia", city]
    fallback_cmd = ["java", f"-Dexporter.baseDirectory={ROOT}", "-jar", str(JAR), *args, "Washington", "Seattle"]

    try:
        print(f"Running synthea for city={city} patients={patients}...")
        subprocess.check_call(primary_cmd, cwd=str(ROOT))
    except subprocess.CalledProcessError as e:
        print("Primary run failed, falling back to Washington/Seattle model (will map to target city later).", file=sys.stderr)
        print("Error:", e, file=sys.stderr)
        subprocess.check_call(fallback_cmd, cwd=str(ROOT))

    return TEMP_OUT / "fhir"


def patch_addresses_and_collect(fhir_dir: Path, city: str):
    """Return list of patient JSON objects from fhir_dir with addresses patched to the target city."""
    patients = []
    files = sorted([p for p in fhir_dir.glob("*.json") if not p.name.startswith(("practitioner", "hospital"))])
    for f in files:
        try:
            data = json.loads(f.read_text())
        except Exception as ex:
            print(f"Skipping unreadable {f}: {ex}")
            continue

        postal_code = f"V5{random.randint(1,9)}{random.choice('ABCDEFGHIJKLMNOPQRSTUVWXYZ')}{random.randint(1,9)}"
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

        patients.append(data)
    return patients


def upload_to_gcs(local_path: Path, bucket: str, gcs_path: str):
    # accept bucket with or without gs:// prefix
    if bucket.startswith("gs://"):
        bucket_name = bucket[len("gs://"):]
    else:
        bucket_name = bucket
    gsuri = f"gs://{bucket_name}/{gcs_path}"
    print(f"Uploading {local_path} -> {gsuri}")
    subprocess.check_call(["gsutil", "cp", str(local_path), gsuri])
    return gsuri


def load_into_bq(gsuri: str, dataset: str, table: str, project: Optional[str]):
    dest = f"{dataset}.{table}"
    cmd = ["bq", "load", "--source_format=NEWLINE_DELIMITED_JSON", "--autodetect"]
    if project:
        cmd += ["--project_id", project]
    cmd += [dest, gsuri]
    print(f"Loading {gsuri} into BigQuery table {dest}...")
    subprocess.check_call(cmd)


def list_buckets(project: Optional[str]) -> list:
    args = ["gsutil", "ls"]
    if project:
        # gsutil doesn't take project as flag for ls; switch to gcloud storage buckets list
        out = subprocess.check_output(["gcloud", "storage", "buckets", "list", "--project", project, "--format=value(name)"], text=True)
        return [l.strip() for l in out.splitlines() if l.strip()]
    try:
        out = subprocess.check_output(args, text=True)
        # gsutil ls prints gs:/bucket/
        return [l.replace("gs:/", "").rstrip('/') for l in out.splitlines() if l.strip()]
    except subprocess.CalledProcessError:
        return []


def main(argv=None):
    parser = argparse.ArgumentParser(description="Generate patients and upload batches to BigQuery via GCS")
    parser.add_argument("--total", type=int, default=10000)
    parser.add_argument("--batch-size", type=int, default=100)
    parser.add_argument("--bucket", type=str, required=True, help="GCS bucket name to use (no gs:/ prefix)")
    parser.add_argument("--gcs-prefix", type=str, default="synthea_raw", help="Path prefix inside the bucket")
    parser.add_argument("--dataset", type=str, required=False, help="BigQuery dataset (not required with --skip-load)")
    parser.add_argument("--table", type=str, required=False, help="BigQuery table name (not required with --skip-load)")
    parser.add_argument("--skip-load", action="store_true", help="Upload to GCS only; skip loading into BigQuery")
    parser.add_argument("--project", type=str, default=None, help="GCP project id (optional)")
    parser.add_argument("--build-if-missing", action="store_true")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args(argv)

    # Commands required: always need java + gsutil; require bq/gcloud only when not skipping load
    required_cmds = ["java", "gsutil"]
    if not args.skip_load:
        required_cmds += ["bq", "gcloud"]
    for cmd in required_cmds:
        require_cmd(cmd)

    if not JAR.exists():
        if args.build_if_missing:
            build_jar()
        else:
            raise FileNotFoundError(f"synthea jar not found at {JAR}; set --build-if-missing to build it")

    # Distribution: user mentioned Langley twice; assume combined 30% for Langley
    dist: Dict[str, float] = {
        "Surrey": 0.50,
        "New Westminster": 0.20,
        "Langley": 0.30,
    }

    total = args.total
    batch = args.batch_size
    seed = args.seed

    # simple sanity
    if total % batch != 0:
        print("Warning: total not divisible by batch-size; last batch will be smaller")

    batches = math.ceil(total / batch)
    patient_counter = 1

    for b in range(batches):
        this_batch_size = min(batch, total - b * batch)
        print(f"\n=== Batch {b+1}/{batches}: generating {this_batch_size} patients ===")

        # Determine counts per city for this batch (rounding to integers, adjust last city)
        city_counts = {}
        rem = this_batch_size
        cities = list(dist.keys())
        for i, city in enumerate(cities):
            if i == len(cities) - 1:
                city_counts[city] = rem
            else:
                cnt = int(round(dist[city] * this_batch_size))
                city_counts[city] = cnt
                rem -= cnt

        # collect patients from runs across cities
        batch_patients = []
        for city, cnt in city_counts.items():
            if cnt <= 0:
                continue
            fhir_dir = run_synthea(cnt, city, seed + b)
            if not fhir_dir.exists():
                raise RuntimeError(f"Expected FHIR output directory not found: {fhir_dir}")
            patients = patch_addresses_and_collect(fhir_dir, city)
            batch_patients.extend(patients)

            # cleanup temp output
            try:
                shutil.rmtree(TEMP_OUT)
            except Exception:
                pass

        # write NDJSON (one JSON object per line)
        batch_file = ROOT / f"analytics/batch_{b+1:04d}.ndjson"
        with batch_file.open("w", encoding="utf-8") as fh:
            for p in batch_patients:
                fh.write(json.dumps(p))
                fh.write("\n")

        # upload to GCS and load into BigQuery
        gcs_path = f"{args.gcs_prefix}/batch_{b+1:04d}.ndjson"
        gsuri = upload_to_gcs(batch_file, args.bucket, gcs_path)
        if not args.skip_load:
            if not args.dataset or not args.table:
                raise RuntimeError("dataset and table are required unless --skip-load is used")
            load_into_bq(gsuri, args.dataset, args.table, args.project)

        # delete local batch file
        try:
            batch_file.unlink()
            print(f"Deleted local batch file {batch_file}")
        except Exception as ex:
            print(f"Warning: failed to delete local batch file {batch_file}: {ex}")

        # small pause
        time.sleep(0.1)

    print(f"\n✓ Completed: generated and uploaded {total} patients in {batches} batches to {args.bucket}/{args.gcs_prefix}")


if __name__ == "__main__":
    main()
