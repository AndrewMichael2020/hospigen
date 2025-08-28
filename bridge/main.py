# bridge/main.py
import base64, json, os, re, hashlib, datetime as dt, typing as t
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse

from google.cloud import pubsub_v1
import google.auth
from google.auth.transport.requests import AuthorizedSession

app = FastAPI()

# Prefer explicit env, fall back to Cloud Run's GOOGLE_CLOUD_PROJECT (if set)
ENV_PROJECT = os.environ.get("PROJECT_ID") or os.environ.get("GOOGLE_CLOUD_PROJECT")
PUBLISHER = pubsub_v1.PublisherClient()

# at the top, near ENV_PROJECT
RESULTS_PRELIM_TOPIC = os.environ.get("RESULTS_PRELIM_TOPIC", "results.prelim")
RESULTS_FINAL_TOPIC  = os.environ.get("RESULTS_FINAL_TOPIC",  "results.final")

def map_observation_topic(res: dict) -> t.Optional[str]:
    status = (res.get("status") or "").lower()
    if status == "final":
        return RESULTS_FINAL_TOPIC
    if status:  # preliminary/registered/etc.
        return RESULTS_PRELIM_TOPIC
    return None


def now_iso() -> str:
    return dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"

def sha256(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()

def project_from_path(path: str) -> t.Optional[str]:
    """Extract 'hospigen' from 'projects/hospigen/...'. """
    m = re.search(r"projects/([^/]+)/", path or "")
    return m.group(1) if m else None

def topic_path(topic: str, project_id: str) -> str:
    return topic if topic.startswith("projects/") else f"projects/{project_id}/topics/{topic}"

def extract_resource_name(data_b64: str) -> t.Optional[str]:
    """Healthcare FHIR notifications: base64(JSON) with 'name' or 'resourceName', or a plain string."""
    try:
        decoded = base64.b64decode(data_b64).decode("utf-8", errors="ignore")
    except Exception:
        return None
    # JSON form
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
    # Plain string fallback
    m = re.search(r"projects/.+?/datasets/.+?/fhirStores/.+?/fhir/.+?/[^/\s]+", decoded)
    return m.group(0) if m else None

def fetch_fhir(resource_name: str) -> dict:
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    session = AuthorizedSession(creds)
    url = f"https://healthcare.googleapis.com/v1/{resource_name}"
    resp = session.get(url, timeout=10)
    resp.raise_for_status()
    return resp.json()

def occurred_at_from(res: dict) -> str:
    return (
        res.get("effectiveDateTime")
        or res.get("issued")
        or res.get("meta", {}).get("lastUpdated")
        or now_iso()
    )

def build_envelope(topic: str, res: dict) -> dict:
    resource_type = res.get("resourceType", "Unknown")
    resource_id   = res.get("id")
    occurred_at   = occurred_at_from(res)
    patient_ref   = (res.get("subject") or {}).get("reference")
    eid_basis     = f"{topic}|{resource_type}|{resource_id or ''}|{occurred_at}|{res.get('status','')}"
    return {
        "event_id": sha256(eid_basis),
        "topic": topic,
        "occurred_at": occurred_at,
        "published_at": now_iso(),
        "patient_ref": patient_ref,
        "resource_type": resource_type,
        "resource_id": resource_id,
        "resource": json.dumps(res, separators=(",", ":")),
        "provenance": {
            "source_system": "gcp.fhir.changes",
            "logic_id": "bridge.obs_router.v1",
            "inputs_span": f"[{occurred_at},{now_iso()}]",
            "trace": None
        }
    }

def publish(topic: str, envelope: dict, project_id: str) -> str:
    data = json.dumps(envelope, separators=(",", ":")).encode("utf-8")
    return PUBLISHER.publish(topic_path(topic, project_id), data=data, origin="bridge").result(timeout=10)

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

    # Derive project for this message: env → storeName attr → resource name
    project_id = (
        ENV_PROJECT
        or project_from_path(attrs.get("storeName", ""))
        or None
    )

    res_name = extract_resource_name(data_b64)
    if not project_id and res_name:
        project_id = project_from_path(res_name)

    if not project_id:
        # Return 500 so Pub/Sub retries rather than dropping the message
        return JSONResponse({"status": "error", "reason": "project_id not found"}, status_code=500)

    try:
        res = fetch_fhir(res_name)
    except Exception as e:
        # 500 → retry; 200 would ack and drop
        return JSONResponse({"status": "error", "reason": f"fetch failed: {e}"}, status_code=500)

    if res.get("resourceType") == "Observation":
        topic = map_observation_topic(res)
        if topic:
            env = build_envelope(topic, res)
            mid = publish(topic, env, project_id=project_id)
            return JSONResponse({"status": "ok", "published_to": topic, "project": project_id, "messageId": mid}, status_code=200)

    return JSONResponse({"status": "ignored", "reason": "no mapping"}, status_code=200)
