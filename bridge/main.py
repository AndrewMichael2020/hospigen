import os, json, re, base64, hashlib, datetime as dt, typing as t
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse

from google.cloud import pubsub_v1
import google.auth
from google.auth.transport.requests import AuthorizedSession

app = FastAPI()

# ---- config (envs) -----------------------------------------------------------
PROJECT_ENV = os.getenv("PROJECT_ID") or os.getenv("GOOGLE_CLOUD_PROJECT")

RESULTS_PRELIM_TOPIC = os.getenv("RESULTS_PRELIM_TOPIC", "results.prelim")
RESULTS_FINAL_TOPIC  = os.getenv("RESULTS_FINAL_TOPIC",  "results.final.v1")
ED_TRIAGE_TOPIC     = os.getenv("ED_TRIAGE_TOPIC",     "ed.triage")

ADT_ADMIT_TOPIC      = os.getenv("ADT_ADMIT_TOPIC",      "adt.admit")
ADT_DISCHARGE_TOPIC  = os.getenv("ADT_DISCHARGE_TOPIC",  "adt.discharge")
ADT_TRANSFER_TOPIC   = os.getenv("ADT_TRANSFER_TOPIC",   "adt.transfer")

PUBLISHER = pubsub_v1.PublisherClient()

# ---- helpers ----------------------------------------------------------------
def now_iso() -> str:
    return dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"

def sha256(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()

def project_from_path(path: str) -> t.Optional[str]:
    m = re.search(r"projects/([^/]+)/", path or "")
    return m.group(1) if m else None

def topic_path(topic: str, project_id: str) -> str:
    return topic if topic.startswith("projects/") else f"projects/{project_id}/topics/{topic}"

def extract_resource_name(data_b64: str) -> t.Optional[str]:
    # Healthcare push -> base64(JSON) with 'name' or 'resourceName', or a plain string path
    try:
        decoded = base64.b64decode(data_b64).decode("utf-8", errors="ignore")
    except Exception:
        return None
    try:
        j = json.loads(decoded)
        if isinstance(j, dict):
            cand = j.get("resourceName") or j.get("name")
            if isinstance(cand, str):
                return cand
        if isinstance(j, str):
            decoded = j
    except Exception:
        pass
    m = re.search(r"projects/.+?/datasets/.+?/fhirStores/.+?/fhir/.+?/[^/\s]+", decoded)
    return m.group(0) if m else None

def fetch_fhir(resource_name: str) -> dict:
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    session = AuthorizedSession(creds)
    url = f"https://healthcare.googleapis.com/v1/{resource_name}"
    resp = session.get(url, timeout=10)
    resp.raise_for_status()
    return resp.json()

def choose_topic_for_observation(res: dict) -> t.Optional[str]:
    status = (res.get("status") or "").lower()
    cls_code = (res.get("class") or {}).get("code","").upper()
    # ED triage: new ED encounter arrival => ed.triage
    if cls_code == "EMER":
        if action == "CreateResource":
            return ED_TRIAGE_TOPIC

    if status == "final":
        return RESULTS_FINAL_TOPIC
    if status:
        return RESULTS_PRELIM_TOPIC
    return None

def choose_topic_for_encounter(res: dict, action: str | None) -> t.Optional[str]:
    # Minimal ADT:
    # - Create in-progress/arrived -> admit
    # - Update while in-progress   -> transfer
    # - finished                   -> discharge
    status = (res.get("status") or "").lower()
    cls_code = (res.get("class") or {}).get("code","").upper()
    # ED triage: new ED encounter arrival => ed.triage
    if cls_code == "EMER":
        if action == "CreateResource":
            return ED_TRIAGE_TOPIC

    if status in ("in-progress", "arrived"):
        if action == "UpdateResource":
            return ADT_TRANSFER_TOPIC
        return ADT_ADMIT_TOPIC
    if status == "finished":
        return ADT_DISCHARGE_TOPIC
    return None

def occurred_at(res: dict) -> str:
    rt = res.get("resourceType")
    if rt == "Encounter":
        period = res.get("period") or {}
        if (res.get("status") or "").lower() == "finished" and period.get("end"):
            return period["end"]
        if period.get("start"):
            return period["start"]
    return (
        res.get("effectiveDateTime")
        or res.get("issued")
        or res.get("meta", {}).get("lastUpdated")
        or now_iso()
    )

def build_envelope(topic: str, res: dict) -> dict:
    rt   = res.get("resourceType", "Unknown")
    rid  = res.get("id", "")
    occ  = occurred_at(res)
    pat  = (res.get("subject") or {}).get("reference")
    event_id = sha256(f"{topic}|{rt}|{rid}|{occ}|{res.get('status','')}")
    return {
        "event_id": event_id,
        "topic": topic,
        "occurred_at": occ,
        "published_at": now_iso(),
        "patient_ref": pat,
        "resource_type": rt,
        "resource_id": rid,
        "resource": json.dumps(res, separators=(",", ":")),
        "provenance": {
            "source_system": "gcp.fhir.changes",
            "logic_id": "bridge.router.v3.ed",
            "inputs_span": f"[{occ},{now_iso()}]",
            "trace": None
        }
    }

def publish(topic: str, envelope: dict, project_id: str) -> str:
    data = json.dumps(envelope, separators=(",", ":")).encode("utf-8")
    tpath = topic_path(topic, project_id)
    return PUBLISHER.publish(tpath, data=data, origin="bridge").result(timeout=10)

# ---- endpoints ---------------------------------------------------------------
@app.get("/health")
def health():
    return PlainTextResponse("ok")

@app.post("/pubsub/push")
async def pubsub_push(request: Request):
    body = await request.json()
    msg  = (body or {}).get("message") or {}
    attrs = msg.get("attributes") or {}
    data_b64 = msg.get("data")
    if not data_b64:
        return JSONResponse({"status": "ignored", "reason": "no data"}, status_code=200)

    project_id = PROJECT_ENV or project_from_path(attrs.get("storeName", ""))

    res_name = extract_resource_name(data_b64)
    if not project_id and res_name:
        project_id = project_from_path(res_name)
    if not project_id:
        return JSONResponse({"status": "error", "reason": "project_id not found"}, status_code=500)

    try:
        res = fetch_fhir(res_name)
    except Exception as e:
        return JSONResponse({"status": "error", "reason": f"fetch failed: {e}"}, status_code=500)

    rtype = res.get("resourceType")
    action = attrs.get("action")  # CreateResource / UpdateResource / DeleteResource

    if rtype == "Observation":
        topic = choose_topic_for_observation(res)
        if topic:
            env = build_envelope(topic, res)
            try:
                mid = publish(topic, env, project_id)
                return JSONResponse({"status": "ok", "published_to": topic, "project": project_id, "messageId": mid}, status_code=200)
            except Exception as e:
                return JSONResponse({"status": "error", "reason": f"publish failed: {e}"}, status_code=500)

    if rtype == "Encounter":
        topic = choose_topic_for_encounter(res, action)
        if topic:
            env = build_envelope(topic, res)
            try:
                mid = publish(topic, env, project_id)
                return JSONResponse({"status": "ok", "published_to": topic, "project": project_id, "messageId": mid}, status_code=200)
            except Exception as e:
                return JSONResponse({"status": "error", "reason": f"publish failed: {e}"}, status_code=500)

    return JSONResponse({"status": "ignored", "reason": "no mapping"}, status_code=200)