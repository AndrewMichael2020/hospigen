import os
import json
import time
import glob
import shlex
import random
import asyncio
import subprocess
from pathlib import Path
from typing import Dict, Any, List, Optional

import httpx

ROOT = Path(__file__).resolve().parents[2]
SYN_DIR = ROOT / "synthea"
DL_DIR = SYN_DIR / "downloads"
RES_DIR = SYN_DIR / "resources"
CFG_DIR = SYN_DIR / "config"
OUT_DIR = SYN_DIR / "output"

JAR = DL_DIR / "synthea-with-dependencies.jar"
PROP_FILE = CFG_DIR / "synthea-canada.properties"

FHIR_API_BASE = "https://healthcare.googleapis.com/v1"

class RunConfig:
    def __init__(self,
                 province: Optional[str],
                 city: Optional[str],
                 count: int,
                 seed: Optional[int],
                 dry_run: bool,
                 max_qps: float,
                 fhir_store: str):
        self.province = province
        self.city = city
        self.count = count
        self.seed = seed
        self.dry_run = dry_run
        self.max_qps = max_qps
        self.fhir_store = fhir_store.rstrip("/")


def ensure_assets() -> None:
    if not JAR.exists():
        raise FileNotFoundError(f"Missing Synthea JAR: {JAR}")
    if not (RES_DIR / "modules").exists():
        raise FileNotFoundError(f"Missing modules dir: {RES_DIR/'modules'}")
    if not (RES_DIR / "geography").exists():
        raise FileNotFoundError(f"Missing geography dir: {RES_DIR/'geography'}")


def run_synthea(cfg: RunConfig) -> Path:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    java_opts = [
        f"-Dgenerate.geography.directory={RES_DIR / 'geography'}",
        "-Dgenerate.geography.country_code=CAN",
        f"-Dexporter.baseDirectory={OUT_DIR}",
    ]
    args = [
        "-p", str(PROP_FILE),
        "-m", str(RES_DIR / 'modules'),
        "-c", str(cfg.count),
    ]
    if cfg.seed is not None:
        args += ["-s", str(cfg.seed)]
    if cfg.province:
        args += ["-state", cfg.province]
    if cfg.city:
        args += ["-city", cfg.city]

    cmd = [
        "java",
        *java_opts,
        "-jar", str(JAR),
        *args,
    ]
    print("Running:", " ".join(shlex.quote(x) for x in cmd))
    subprocess.check_call(cmd, cwd=str(ROOT))
    return OUT_DIR / "fhir"


def iter_transaction_bundles(fhir_dir: Path) -> List[Path]:
    return sorted(fhir_dir.glob("*.json"))


def get_access_token() -> str:
    # In Cloud Run, use metadata server to get access token for Healthcare API
    try:
        import requests
        r = requests.get(
            "http://metadata/computeMetadata/v1/instance/service-accounts/default/token",
            headers={"Metadata-Flavor": "Google"}, timeout=1.5,
        )
        if r.status_code == 200:
            return r.json().get("access_token", "")
    except Exception:
        pass
    # Fallback locally
    token = os.popen("gcloud auth print-access-token").read().strip()
    if not token:
        raise RuntimeError("Unable to obtain access token")
    return token


async def post_bundle(session: httpx.AsyncClient, fhir_store: str, bundle: Dict[str, Any]) -> httpx.Response:
    # If fhir_store begins with projects/..., prepend API base
    url = fhir_store
    if url.startswith("projects/"):
        url = f"{FHIR_API_BASE}/{url}"
    if not url.endswith("/fhir"):
        url = url + "/fhir"
    return await session.post(url, json=bundle, timeout=60.0)


async def upload_bundles(fhir_store: str, bundles_dir: Path, max_qps: float, dry_run: bool) -> Dict[str, Any]:
    files = iter_transaction_bundles(bundles_dir)
    success = 0
    failed = 0
    errors: List[str] = []

    headers = {"Authorization": f"Bearer {get_access_token()}"}
    async with httpx.AsyncClient(headers=headers) as session:
        interval = 1.0 / max_qps if max_qps > 0 else 0
        for path in files:
            try:
                with path.open("r") as f:
                    bundle = json.load(f)
                if dry_run:
                    success += 1
                else:
                    # retry a few times on 429/5xx
                    for attempt in range(4):
                        resp = await post_bundle(session, fhir_store, bundle)
                        if resp.status_code < 300:
                            success += 1
                            break
                        if resp.status_code in (429, 500, 502, 503, 504):
                            back = (2 ** attempt) + random.random()
                            await asyncio.sleep(back)
                            continue
                        failed += 1
                        errors.append(f"{path.name}: {resp.status_code} {resp.text[:200]}")
                        break
                if interval:
                    await asyncio.sleep(interval)
            except Exception as e:
                failed += 1
                errors.append(f"{path.name}: {e}")

    return {"success": success, "failed": failed, "errors": errors[:20]}


def execute(cfg: RunConfig) -> Dict[str, Any]:
    ensure_assets()
    out_dir = run_synthea(cfg)
    result = {
        "generated_dir": str(out_dir),
        "count": cfg.count,
        "province": cfg.province,
        "city": cfg.city,
    }
    upload = asyncio.run(upload_bundles(cfg.fhir_store, out_dir, cfg.max_qps, cfg.dry_run))
    result.update(upload)
    return result
