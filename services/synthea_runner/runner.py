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
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
SYN_DIR = ROOT / "synthea"
DL_DIR = SYN_DIR / "downloads"
# Prefer container path if present, else use repo sources
RES_DIR_CANDIDATES = [
    SYN_DIR / "resources",  # container copy target
    SYN_DIR / "src" / "main" / "resources",  # repo location
]
def _resolve_res_dir() -> Path:
    for p in RES_DIR_CANDIDATES:
        if p.exists():
            return p
    # default to first candidate even if missing (jar has built-ins)
    return RES_DIR_CANDIDATES[0]
RES_DIR = _resolve_res_dir()
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
                 fhir_store: str,
                 country: str = "CA"):
        self.province = province
        self.city = city
        self.count = count
        self.seed = seed
        self.dry_run = dry_run
        self.max_qps = max_qps
        self.fhir_store = fhir_store.rstrip("/")
        self.country = country.upper()


def ensure_assets(country: str) -> None:
    if not JAR.exists():
        # Attempt to download the Synthea JAR for local runs
        JAR.parent.mkdir(parents=True, exist_ok=True)
        version = os.environ.get("SYNTH_VERSION", "v3.0.0")
        jar_name = os.environ.get("SYNTH_JAR", "synthea-with-dependencies.jar")
        url = f"https://github.com/synthetichealth/synthea/releases/download/{version}/{jar_name}"
        print(f"Downloading Synthea JAR from {url} to {JAR} ...")
        urllib.request.urlretrieve(url, str(JAR))
        if not JAR.exists():
            raise FileNotFoundError(f"Missing Synthea JAR after download attempt: {JAR}")
    # For CA we require local geography CSVs; for US we rely on built-in resources in the JAR
    if country.upper() == "CA":
        # Optional local resources; Synthea jar includes CA assets too
        pass
    elif country.upper() == "US":
        # Nothing extra needed; Synthea jar contains default US resources
        pass
    else:
        raise ValueError(f"Unsupported COUNTRY '{country}'. Only 'CA' and 'US' are supported.")


def run_synthea(cfg: RunConfig) -> Path:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    java_opts = [
        f"-Dexporter.baseDirectory={OUT_DIR}",
    ]
    if cfg.country == "CA":
        # Use CA geography from our resources folder when present; else rely on JAR assets
        geo_dir = RES_DIR / 'geography'
        java_opts.insert(0, "-Dgenerate.geography.country_code=CA")
        if geo_dir.exists():
            java_opts.insert(0, f"-Dgenerate.geography.directory={geo_dir}")
            print(f"Using local geography dir: {geo_dir}")
        else:
            print("No local geography dir found; relying on Synthea JAR assets for CA")
    elif cfg.country == "US":
        # Use built-in US geography (no override directory), but set explicit country code
        java_opts.insert(0, "-Dgenerate.geography.country_code=US")
    else:
        raise ValueError(f"Unsupported COUNTRY '{cfg.country}'. Only 'CA' and 'US' are supported.")
    # Synthea CLI:
    #  -c <configPath> (local config file)
    #  -p <populationSize>
    #  -d <modulesDir> (optional)
    #  [state [city]] as positional args
    args = [
        "-c", str(PROP_FILE),
        "-p", str(cfg.count),
    ]
    modules_dir = RES_DIR / 'modules'
    # Use modules directory only if it contains JSON modules; otherwise rely on defaults in the JAR
    if modules_dir.exists() and any(modules_dir.glob('*.json')):
        args += ["-d", str(modules_dir)]
    if cfg.seed is not None:
        args += ["-s", str(cfg.seed)]
    # Positional geography: state/province and city
    if cfg.province:
        args += [cfg.province]
    if cfg.city:
        args += [cfg.city]

    cmd = [
        "java",
        *java_opts,
        "-jar", str(JAR),
        *args,
    ]
    print("Running:", " ".join(shlex.quote(x) for x in cmd))
    try:
        subprocess.check_call(cmd, cwd=str(ROOT))
    except subprocess.CalledProcessError as e:
        # If a specific city was requested and Synthea failed to locate it in demographics,
        # retry once with province-only to avoid a hard failure.
        if cfg.city:
            print(f"Synthea failed with city '{cfg.city}' (exit {e.returncode}). Retrying without city...")
            retry_args = [
                "java",
                *java_opts,
                "-jar", str(JAR),
                *["-c", str(PROP_FILE), "-p", str(cfg.count)],
            ]
            if modules_dir.exists() and any(modules_dir.glob('*.json')):
                retry_args += ["-d", str(modules_dir)]
            if cfg.seed is not None:
                retry_args += ["-s", str(cfg.seed)]
            if cfg.province:
                retry_args += [cfg.province]
            print("Running (fallback):", " ".join(shlex.quote(x) for x in retry_args))
            subprocess.check_call(retry_args, cwd=str(ROOT))
        else:
            raise
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

    # If dry_run, just count bundles and return without network calls
    if dry_run:
        for path in files:
            try:
                with path.open("r") as f:
                    json.load(f)
                success += 1
            except Exception as e:
                failed += 1
                errors.append(f"{path.name}: {e}")
        return {"success": success, "failed": failed, "errors": errors[:20]}

    headers = {"Authorization": f"Bearer {get_access_token()}"}
    async with httpx.AsyncClient(headers=headers) as session:
        interval = 1.0 / max_qps if max_qps > 0 else 0
        for path in files:
            try:
                with path.open("r") as f:
                    bundle = json.load(f)
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
    ensure_assets(cfg.country)
    out_dir = run_synthea(cfg)
    result = {
        "generated_dir": str(out_dir),
        "count": cfg.count,
        "province": cfg.province,
        "city": cfg.city,
        "country": cfg.country,
    }
    upload = asyncio.run(upload_bundles(cfg.fhir_store, out_dir, cfg.max_qps, cfg.dry_run))
    result.update(upload)
    return result
