import os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from typing import Optional

from .runner import RunConfig, execute

app = FastAPI(title="Synthea Runner", version="1.0")

class GenerateRequest(BaseModel):
    province: Optional[str] = Field(None, description="Province name e.g. 'British Columbia'")
    city: Optional[str] = Field(None, description="City name e.g. 'Surrey'")
    count: int = Field(10, ge=1, le=10000)
    seed: Optional[int] = None
    dry_run: bool = False
    max_qps: float = 3.0

@app.get("/healthz")
async def health() -> dict:
    return {"ok": True}

@app.post("/generate")
async def generate(req: GenerateRequest):
    fhir_store = os.environ.get("FHIR_STORE") or os.environ.get("STORE_ID_PATH")
    if not fhir_store:
        raise HTTPException(500, detail="Missing FHIR_STORE env")
    cfg = RunConfig(
        province=req.province,
        city=req.city,
        count=req.count,
        seed=req.seed,
        dry_run=req.dry_run,
        max_qps=req.max_qps,
        fhir_store=fhir_store,
    )
    try:
        result = execute(cfg)
        return result
    except Exception as e:
        raise HTTPException(500, detail=str(e))
