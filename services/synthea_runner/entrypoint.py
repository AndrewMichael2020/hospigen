import os
import traceback
import importlib

MODE = os.environ.get("MODE", "service").lower()

if MODE == "service":
    from services.synthea_runner.app import app
    uvicorn = importlib.import_module("uvicorn")
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
else:
    # job mode - read envs and execute once
    from services.synthea_runner.runner import RunConfig, execute
    # Read and sanitize geography inputs (strip accidental wrapping quotes)
    def _clean(val: str | None) -> str | None:
        if val is None:
            return None
        v = val.strip()
        # remove one layer of matching quotes if present
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            v = v[1:-1].strip()
        return v

    # Extract and normalize province/city
    raw_province = os.environ.get("PROVINCE")
    raw_city = os.environ.get("CITY")
    province = _clean(raw_province)
    city = _clean(raw_city)
    # Normalize province/city: Cloud Run env may show spaces as underscores in describe output
    if province:
        province = province.replace("_", " ")
    if city:
        city = city.replace("_", " ")
    # Expand common Canadian province abbreviations to full names for demographics lookup
    # while keeping the short code available in a parallel variable if needed in the future.
    prov_map = {
        "BC": "British Columbia",
        "AB": "Alberta",
        "SK": "Saskatchewan",
        "MB": "Manitoba",
        "ON": "Ontario",
        "QC": "Quebec",
        "NB": "New Brunswick",
        "NS": "Nova Scotia",
        "PE": "Prince Edward Island",
        "NL": "Newfoundland and Labrador",
        "YT": "Yukon",
        "NT": "Northwest Territories",
        "NU": "Nunavut",
    }
    if province in prov_map:
        province = prov_map[province]
    count = int(os.environ.get("COUNT", "10"))
    seed = os.environ.get("SEED")
    seed_int = int(seed) if seed is not None and seed != "" else None
    dry_run = os.environ.get("DRY_RUN", "false").lower() == "true"
    max_qps = float(os.environ.get("MAX_QPS", "3"))
    fhir_store = os.environ.get("FHIR_STORE") or os.environ.get("STORE_ID_PATH")
    if not fhir_store:
        raise RuntimeError("Missing FHIR_STORE env")
    country = (os.environ.get("COUNTRY") or "CA").upper()
    cfg = RunConfig(province=province, city=city, count=count, seed=seed_int, dry_run=dry_run, max_qps=max_qps, fhir_store=fhir_store, country=country)
    print("Env raw values:", {"PROVINCE": raw_province, "CITY": raw_city})
    print("Starting synthea-runner job once with:", cfg.__dict__)
    try:
        res = execute(cfg)
        print("Result:", res)
    except Exception:
        print("Job execution failed with exception:")
        traceback.print_exc()
        raise
