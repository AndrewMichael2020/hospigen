import os
import uvicorn

MODE = os.environ.get("MODE", "service").lower()

if MODE == "service":
    from services.synthea_runner.app import app
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
else:
    # job mode - read envs and execute once
    from services.synthea_runner.runner import RunConfig, execute
    province = os.environ.get("PROVINCE")
    city = os.environ.get("CITY")
    count = int(os.environ.get("COUNT", "10"))
    seed = os.environ.get("SEED")
    seed_int = int(seed) if seed is not None and seed != "" else None
    dry_run = os.environ.get("DRY_RUN", "false").lower() == "true"
    max_qps = float(os.environ.get("MAX_QPS", "3"))
    fhir_store = os.environ.get("FHIR_STORE") or os.environ.get("STORE_ID_PATH")
    if not fhir_store:
        raise RuntimeError("Missing FHIR_STORE env")
    cfg = RunConfig(province=province, city=city, count=count, seed=seed_int, dry_run=dry_run, max_qps=max_qps, fhir_store=fhir_store)
    print("Starting synthea-runner job once with:", cfg.__dict__)
    res = execute(cfg)
    print("Result:", res)
