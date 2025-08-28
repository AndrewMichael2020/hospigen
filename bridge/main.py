import os, json, base64, traceback
from fastapi import FastAPI, Request
from google.cloud import pubsub_v1

app = FastAPI()

OUTPUT_TOPIC = os.getenv("OUTPUT_TOPIC", "projects/hospigen/topics/results.final")
publisher = pubsub_v1.PublisherClient()


def _coerce_resource(v):
    print(">>> _coerce_resource input:", type(v), repr(v)[:200])
    try:
        if isinstance(v, dict):
            return v
        if isinstance(v, (bytes, bytearray)):
            return json.loads(v.decode("utf-8"))
        if isinstance(v, str):
            s = v.strip()
            if s and s[0] in "{[":
                return json.loads(s)
            return {"raw": s}
    except Exception as e:
        print("!!! _coerce_resource failed:", e)
        traceback.print_exc()
    return {"raw": str(v)}


def to_envelope(resource: dict) -> dict:
    try:
        print(">>> to_envelope resource:", resource)
        rid = resource.get("id", "no-id")
        rtype = resource.get("resourceType", "Observation")
        t = resource.get("effectiveDateTime", "2025-01-01T00:00:00Z")
        env = {
            "event_id": rid,
            "topic": "results.final",
            "occurred_at": t,
            "published_at": t,
            "patient_ref": {"string": "Patient/diag"},
            "resource_type": rtype,
            "resource": json.dumps(resource, separators=(",", ":")),
            "provenance": {
                "source_system": "bridge",
                "logic_id": "wrap-v1",
                "inputs_span": f"FHIR:{rtype}/{rid}",
                "trace": None,
            },
        }
        print(">>> to_envelope result:", env)
        return env
    except Exception as e:
        print("!!! to_envelope failed:", e)
        traceback.print_exc()
        raise

def _looks_like_envelope(obj: dict) -> bool:
    required = {"event_id","topic","resource_type","resource","provenance"}
    return isinstance(obj, dict) and required.issubset(obj.keys())

@app.post("/pubsub/push")
async def pubsub_push(request: Request):
    try:
        body = await request.json()
        print(">>> Incoming request body:", body)

        attrs = {}
        if isinstance(body, dict) and "message" in body and isinstance(body["message"], dict):
            attrs = body["message"].get("attributes", {}) or {}
            if "data" in body["message"]:
                raw = base64.b64decode(body["message"]["data"]).decode("utf-8")
                print(">>> Decoded Pub/Sub data:", raw)
                payload = json.loads(raw)
            else:
                return {"error": "missing data"}
        else:
            payload = body

        # If payload is already an envelope, do not re-publish
        if _looks_like_envelope(payload):
            print(">>> Already an envelope; skipping republish.")
            return {"status": "skipped"}

        resource = payload.get("resource", payload)
        resource = _coerce_resource(resource)
        env = to_envelope(resource)
        data = json.dumps(env, separators=(",", ":")).encode("utf-8")

        print(">>> Publishing to topic:", OUTPUT_TOPIC)
        future = publisher.publish(OUTPUT_TOPIC, data=data, origin="bridge")
        msg_id = future.result(timeout=10)
        print(">>> Published messageId:", msg_id)
        return {"status": "ok", "messageId": msg_id}
    except Exception as e:
        print("!!! pubsub_push failed:", e)
        traceback.print_exc()
        return {"error": str(e)}

