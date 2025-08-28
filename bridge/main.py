import os, json, base64, hashlib, typing as t
from datetime import datetime, timezone
import requests
import google.auth
from google.auth.transport.requests import Request as GAuthRequest

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from google.cloud import pubsub_v1

app = FastAPI()

# -----------------------------
# Env / topics
# -----------------------------
PROJECT_ENV = os.getenv("PROJECT_ID") or os.getenv("GOOGLE_CLOUD_PROJECT")

RESULTS_PRELIM_TOPIC       = os.getenv("RESULTS_PRELIM_TOPIC",       "results.prelim")
RESULTS_FINAL_TOPIC        = os.getenv("RESULTS_FINAL_TOPIC",        "results.final.v1")
ORDERS_CREATED_TOPIC       = os.getenv("ORDERS_CREATED_TOPIC",       "orders.created")
MEDS_ORDERED_TOPIC         = os.getenv("MEDS_ORDERED_TOPIC",         "meds.ordered")
MEDS_ADMINISTERED_TOPIC    = os.getenv("MEDS_ADMINISTERED_TOPIC",    "meds.administered")
PROCEDURES_PERFORMED_TOPIC = os.getenv("PROCEDURES_PERFORMED_TOPIC", "procedures.performed")
NOTES_CREATED_TOPIC        = os.getenv("NOTES_CREATED_TOPIC",        "notes.created")
SCHED_CREATED_TOPIC        = os.getenv("SCHEDULING_CREATED_TOPIC",   "scheduling.created")
ED_TRIAGE_TOPIC            = os.getenv("ED_TRIAGE_TOPIC",            "ed.triage")
ADT_ADMIT_TOPIC            = os.getenv("ADT_ADMIT_TOPIC",            "adt.admit")
ADT_TRANSFER_TOPIC         = os.getenv("ADT_TRANSFER_TOPIC",         "adt.transfer")
ADT_DISCHARGE_TOPIC        = os.getenv("ADT_DISCHARGE_TOPIC",        "adt.discharge")
RPM_OBS_CREATED_TOPIC      = os.getenv("RPM_OBS_CREATED_TOPIC",      "rpm.observation.created")

LOGIC_ID = os.getenv("LOGIC_ID", "bridge.router.v4")

PUBLISHER = pubsub_v1.PublisherClient()

# -----------------------------
# Utilities
# -----------------------------
def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()

def get_project_id() -> str:
    if PROJECT_ENV:
        return PROJECT_ENV
    creds, project_id = google.auth.default()
    return project_id

def topic_path(topic: str, project_id: t.Optional[str] = None) -> str:
    if topic.startswith("projects/"):
        return topic
    pid = project_id or get_project_id()
    return f"projects/{pid}/topics/{topic}"

def fetch_fhir_resource_by_name(name: str) -> dict:
    # name like projects/.../fhirStores/.../fhir/Observation/xyz
    url = name if name.startswith("https://") else f"https://healthcare.googleapis.com/v1/{name}"
    creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    creds.refresh(GAuthRequest())
    headers = {
        "Authorization": f"Bearer {creds.token}",
        "Accept": "application/fhir+json",
    }
    r = requests.get(url, headers=headers, timeout=10)
    r.raise_for_status()
    return r.json()

def resource_patient_ref(res: dict) -> t.Optional[str]:
    # Common case
    subj = res.get("subject") or {}
    if isinstance(subj, dict) and isinstance(subj.get("reference"), str):
        return subj["reference"]
    # Appointment: participant[].actor.reference
    if res.get("resourceType") == "Appointment":
        for p in res.get("participant") or []:
            actor = p.get("actor") or {}
            ref = actor.get("reference")
            if isinstance(ref, str) and ("Patient/" in ref):
                return ref
    return None

def occurred_at(res: dict) -> str:
    rt = res.get("resourceType")
    if rt == "Observation":
        return res.get("effectiveDateTime") or res.get("issued") or res.get("meta", {}).get("lastUpdated") or now_iso()
    if rt == "ServiceRequest":
        return res.get("authoredOn") or res.get("meta", {}).get("lastUpdated") or now_iso()
    if rt == "MedicationRequest":
        return res.get("authoredOn") or res.get("meta", {}).get("lastUpdated") or now_iso()
    if rt == "MedicationAdministration":
        eff = res.get("effectiveDateTime")
        if eff:
            return eff
        period = res.get("effectivePeriod") or {}
        return period.get("start") or res.get("meta", {}).get("lastUpdated") or now_iso()
    if rt == "Procedure":
        perf = res.get("performedDateTime")
        if perf:
            return perf
        pp = res.get("performedPeriod") or {}
        return pp.get("start") or res.get("meta", {}).get("lastUpdated") or now_iso()
    if rt == "DocumentReference":
        return res.get("date") or res.get("meta", {}).get("lastUpdated") or now_iso()
    if rt == "Appointment":
        return res.get("start") or res.get("meta", {}).get("lastUpdated") or now_iso()
    if rt == "Encounter":
        per = res.get("period") or {}
        return per.get("start") or res.get("meta", {}).get("lastUpdated") or now_iso()
    return res.get("meta", {}).get("lastUpdated") or now_iso()

def build_envelope(topic: str, res: dict) -> dict:
    rid = res.get("id", "no-id")
    rtype = res.get("resourceType", "Unknown")
    occ = occurred_at(res)
    event_hash_src = f"{rtype}:{rid}:{occ}".encode("utf-8")
    event_id = hashlib.sha256(event_hash_src).hexdigest()
    env = {
        "event_id": event_id,
        "topic": topic,
        "occurred_at": occ,
        "published_at": now_iso(),
        "patient_ref": resource_patient_ref(res),
        "resource_type": rtype,
        "resource_id": rid,
        "resource": json.dumps(res, separators=(",", ":")),
        "provenance": {
            "source_system": "gcp.fhir.changes",
            "logic_id": LOGIC_ID,
            "inputs_span": f"[{occ},{now_iso()}]",
            "trace": None,
        },
    }
    return env

# -----------------------------
# Routing helpers
# -----------------------------
def choose_topic_for_observation(res: dict, action: t.Optional[str] = None) -> t.Optional[str]:
    status = (res.get("status") or "").lower()

    # category: 'laboratory' vs 'vital-signs'
    cat_codes: list[str] = []
    for cat in res.get("category", []) or []:
        for c in (cat.get("coding") or []):
            sys = (c.get("system") or "").lower()
            if sys in (
                "http://terminology.hl7.org/codesystem/observation-category",
                "http://terminology.hl7.org/CodeSystem/observation-category",
                "http://hl7.org/fhir/observation-category",
            ):
                code = (c.get("code") or "").lower()
                if code:
                    cat_codes.append(code)

    is_lab = "laboratory" in cat_codes
    is_vitals = "vital-signs" in cat_codes

    # fallback by known LOINC codes
    codes = {(c.get("system"), c.get("code")) for c in (res.get("code", {}).get("coding") or [])}
    VITALS = {
        ("http://loinc.org", "59408-5"),  # SpO2
        ("http://loinc.org", "8867-4"),   # HR
        ("http://loinc.org", "9279-1"),   # RR
        ("http://loinc.org", "8310-5"),   # Temp
        ("http://loinc.org", "8480-6"),   # Systolic BP
        ("http://loinc.org", "8462-4"),   # Diastolic BP
        ("http://loinc.org", "8302-2"),   # Height
        ("http://loinc.org", "29463-7"),  # Weight
        ("http://loinc.org", "39156-5"),  # BMI
    }

    if is_lab:
        return RESULTS_FINAL_TOPIC if status == "final" else RESULTS_PRELIM_TOPIC
    if is_vitals or (codes & VITALS):
        return RPM_OBS_CREATED_TOPIC
    return None

def choose_topic_for_encounter(res: dict, action: t.Optional[str] = None) -> t.Optional[str]:
    status = (res.get("status") or "").lower()
    cls = ((res.get("class") or {}).get("code") or "").upper()

    # ED triage
    if cls == "EMER":
        if status in ("arrived",):
            return ED_TRIAGE_TOPIC
        return None

    # Inpatient admit/transfer/discharge
    if cls == "IMP":
        if status in ("in-progress", "arrived"):
            if action == "UpdateResource":
                return ADT_TRANSFER_TOPIC
            return ADT_ADMIT_TOPIC
        if status in ("finished", "completed"):
            return ADT_DISCHARGE_TOPIC
    return None

def choose_topic_for_appointment(res: dict, action: t.Optional[str] = None) -> t.Optional[str]:
    status = (res.get("status") or "").lower()
    if action in ("CreateResource", "UpdateResource") or status in (
        "booked", "proposed", "pending", "arrived", "checked-in", "accepted"
    ):
        return SCHED_CREATED_TOPIC
    return None

# -----------------------------
# Pub/Sub publish
# -----------------------------
def publish(topic: str, envelope: dict, project_id: t.Optional[str] = None) -> str:
    data = json.dumps(envelope, separators=(",", ":")).encode("utf-8")
    tpath = topic_path(topic, project_id)
    future = PUBLISHER.publish(tpath, data=data, origin="bridge")
    return future.result(timeout=10)

# -----------------------------
# Coercion helpers
# -----------------------------
def _coerce_resource(v):
    if isinstance(v, dict):
        return v
    if isinstance(v, (bytes, bytearray)):
        try:
            return json.loads(v.decode("utf-8"))
        except Exception:
            return {"raw": v.decode("utf-8", "ignore")}
    if isinstance(v, str):
        s = v.strip()
        if s and s[0] in "{[":
            try:
                return json.loads(s)
            except Exception:
                return {"raw": s}
        return {"raw": s}
    return {"raw": str(v)}

def _looks_like_envelope(obj: dict) -> bool:
    required = {"event_id", "topic", "resource_type", "resource", "provenance"}
    return isinstance(obj, dict) and required.issubset(obj.keys())

# -----------------------------
# Endpoints
# -----------------------------
@app.get("/health")
async def health():
    return JSONResponse({"status": "ok"}, status_code=200)

@app.post("/pubsub/push")
async def pubsub_push(request: Request):
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"status": "error", "reason": "invalid json"}, status_code=400)

    # Pub/Sub wrapper
    attrs = {}
    payload = None
    if isinstance(body, dict) and "message" in body and isinstance(body["message"], dict):
        attrs = body["message"].get("attributes") or {}
        if "data" not in body["message"]:
            return JSONResponse({"status": "error", "reason": "missing data"}, status_code=400)
        try:
            raw = base64.b64decode(body["message"]["data"]).decode("utf-8")
            payload = json.loads(raw)
        except Exception as e:
            return JSONResponse({"status": "error", "reason": f"base64/json decode failed: {e}"}, status_code=400)
    else:
        payload = body

    # If already an envelope, no-op
    if isinstance(payload, dict) and _looks_like_envelope(payload):
        return JSONResponse({"status": "skipped"}, status_code=200)

    # FHIR Notifications: payload may be {"name": ".../fhir/Resource/id"}
    project_id = get_project_id()
    action = attrs.get("action") or payload.get("action") if isinstance(payload, dict) else None

    if isinstance(payload, dict) and "name" in payload:
        try:
            res = fetch_fhir_resource_by_name(payload["name"])
        except Exception as e:
            return JSONResponse({"status": "error", "reason": f"fetch failed: {e}"}, status_code=500)
    else:
        res = _coerce_resource(payload.get("resource", payload))

    rtype = res.get("resourceType")
    if not rtype:
        return JSONResponse({"status": "ignored", "reason": "no resourceType"}, status_code=200)

    # Routing
    topic: t.Optional[str] = None
    if rtype == "Observation":
        topic = choose_topic_for_observation(res, action)
    elif rtype == "ServiceRequest":
        topic = ORDERS_CREATED_TOPIC
    elif rtype == "MedicationRequest":
        topic = MEDS_ORDERED_TOPIC
    elif rtype == "MedicationAdministration":
        topic = MEDS_ADMINISTERED_TOPIC
    elif rtype == "Procedure":
        topic = PROCEDURES_PERFORMED_TOPIC
    elif rtype == "DocumentReference":
        topic = NOTES_CREATED_TOPIC
    elif rtype == "Appointment":
        topic = choose_topic_for_appointment(res, action)
    elif rtype == "Encounter":
        topic = choose_topic_for_encounter(res, action)

    if not topic:
        return JSONResponse({"status": "ignored", "reason": "no mapping"}, status_code=200)

    env = build_envelope(topic, res)
    try:
        mid = publish(topic, env, project_id=project_id)
        return JSONResponse({"status": "ok", "published_to": topic, "project": project_id, "messageId": mid}, status_code=200)
    except Exception as e:
        return JSONResponse({"status": "error", "reason": f"publish failed: {e}"}, status_code=500)
