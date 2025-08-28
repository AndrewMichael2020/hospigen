# /home/andriy_ignatov/hospigen/bridge/test_main.py
import base64
import hashlib
import json
from unittest.mock import patch, Mock

import pytest
from fastapi.testclient import TestClient

from bridge.main import (
    app,
    sha256,
    project_from_path,
    topic_path,
    extract_resource_name,
    map_observation_topic,
    occurred_at_from,
    build_envelope,
    fetch_fhir,
)

client = TestClient(app)

# --- Helper Function Tests ---

def test_sha256():
    test_string = "hello world"
    expected_hash = hashlib.sha256(test_string.encode("utf-8")).hexdigest()
    assert sha256(test_string) == expected_hash

@pytest.mark.parametrize(
    "path, expected",
    [
        ("projects/hospigen/datasets/ds/fhirStores/fs", "hospigen"),
        ("projects/another-proj/topics/t", "another-proj"),
        ("invalid/path", None),
        ("", None),
        (None, None),
    ],
)
def test_project_from_path(path, expected):
    assert project_from_path(path) == expected

@pytest.mark.parametrize(
    "topic, project_id, expected",
    [
        ("my-topic", "my-proj", "projects/my-proj/topics/my-topic"),
        ("projects/my-proj/topics/my-topic", "my-proj", "projects/my-proj/topics/my-topic"),
        ("projects/another-proj/topics/my-topic", "my-proj", "projects/another-proj/topics/my-topic"),
    ],
)
def test_topic_path(topic, project_id, expected):
    assert topic_path(topic, project_id) == expected

@pytest.mark.parametrize(
    "payload, expected_name",
    [
        (json.dumps({"resourceName": "fhir/Resource/123"}), "fhir/Resource/123"),
        (json.dumps({"name": "fhir/Resource/456"}), "fhir/Resource/456"),
        (json.dumps("projects/p/datasets/d/fhirStores/f/fhir/Patient/abc"), "projects/p/datasets/d/fhirStores/f/fhir/Patient/abc"),
        ("projects/p/datasets/d/fhirStores/f/fhir/Observation/xyz", "projects/p/datasets/d/fhirStores/f/fhir/Observation/xyz"),
        ("Notification for projects/p/datasets/d/fhirStores/f/fhir/Encounter/enc1", "projects/p/datasets/d/fhirStores/f/fhir/Encounter/enc1"),
        ("some other string", None),
        (json.dumps({"other_key": "value"}), None),
    ],
)
def test_extract_resource_name(payload, expected_name):
    data_b64 = base64.b64encode(payload.encode("utf-8")).decode("utf-8")
    assert extract_resource_name(data_b64) == expected_name

def test_extract_resource_name_invalid_b64():
    assert extract_resource_name("not-base64") is None

@patch("google.auth.transport.requests.AuthorizedSession")
@patch("google.auth.default", return_value=(Mock(), "test-project"))
def test_fetch_fhir(mock_auth_default, mock_authed_session):
    mock_session_instance = Mock()
    mock_response = Mock()
    mock_response.json.return_value = {"resourceType": "Patient", "id": "123"}
    mock_response.raise_for_status = Mock()
    mock_session_instance.get.return_value = mock_response
    mock_authed_session.return_value = mock_session_instance

    resource_name = "projects/p/datasets/d/fhirStores/f/fhir/Patient/123"
    result = fetch_fhir(resource_name)

    mock_auth_default.assert_called_once_with(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    mock_authed_session.assert_called_once()
    expected_url = f"https://healthcare.googleapis.com/v1/{resource_name}"
    mock_session_instance.get.assert_called_once_with(expected_url, timeout=10)
    mock_response.raise_for_status.assert_called_once()
    assert result == {"resourceType": "Patient", "id": "123"}

@pytest.mark.parametrize(
    "resource, expected_topic",
    [
        ({"status": "final"}, "results.final"),
        ({"status": "preliminary"}, "results.prelim"),
        ({"status": "registered"}, "results.prelim"),
        ({"status": "FINAL"}, "results.final"),
        ({"status": "unknown"}, "results.prelim"),
        ({}, None),
        ({"other_key": "value"}, None),
    ],
)
def test_map_observation_topic(resource, expected_topic, monkeypatch):
    monkeypatch.setenv("RESULTS_FINAL_TOPIC", "results.final")
    monkeypatch.setenv("RESULTS_PRELIM_TOPIC", "results.prelim")
    assert map_observation_topic(resource) == expected_topic

@patch("bridge.main.now_iso", return_value="2025-01-01T00:00:00Z")
@pytest.mark.parametrize(
    "resource, expected_ts",
    [
        ({"effectiveDateTime": "2023-01-01T12:00:00Z"}, "2023-01-01T12:00:00Z"),
        ({"issued": "2023-02-01T12:00:00Z"}, "2023-02-01T12:00:00Z"),
        ({"meta": {"lastUpdated": "2023-03-01T12:00:00Z"}}, "2023-03-01T12:00:00Z"),
        (
            {"issued": "2023-02-01T12:00:00Z", "effectiveDateTime": "2023-01-01T12:00:00Z"},
            "2023-01-01T12:00:00Z",
        ),
        ({}, "2025-01-01T00:00:00Z"),
    ],
)
def test_occurred_at_from(mock_now, resource, expected_ts):
    assert occurred_at_from(resource) == expected_ts

@patch("bridge.main.now_iso", return_value="2025-01-01T00:00:01Z")
@patch("bridge.main.sha256", return_value="mock-event-id")
def test_build_envelope(mock_sha, mock_now):
    res = {
        "resourceType": "Observation",
        "id": "obs1",
        "status": "final",
        "effectiveDateTime": "2025-01-01T00:00:00Z",
        "subject": {"reference": "Patient/123"},
    }
    topic = "results.final"
    envelope = build_envelope(topic, res)

    assert envelope["event_id"] == "mock-event-id"
    assert envelope["topic"] == topic
    assert envelope["occurred_at"] == "2025-01-01T00:00:00Z"
    assert envelope["published_at"] == "2025-01-01T00:00:01Z"
    assert envelope["patient_ref"] == "Patient/123"
    assert envelope["resource_type"] == "Observation"
    assert envelope["resource_id"] == "obs1"
    assert json.loads(envelope["resource"]) == res
    assert envelope["provenance"]["logic_id"] == "bridge.obs_router.v1"

    eid_basis = f"{topic}|{res['resourceType']}|{res['id']}|{res['effectiveDateTime']}|{res['status']}"
    mock_sha.assert_called_once_with(eid_basis)


# --- Endpoint Tests ---

def test_health_check():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.text == "ok"

def test_pubsub_push_no_data():
    response = client.post("/pubsub/push", json={"message": {"attributes": {}}})
    assert response.status_code == 200
    assert response.json() == {"status": "ignored", "reason": "no data"}

@patch("bridge.main.extract_resource_name", return_value="fhir/Observation/123")
def test_pubsub_push_no_project(mock_extract, monkeypatch):
    monkeypatch.delenv("PROJECT_ID", raising=False)
    monkeypatch.delenv("GOOGLE_CLOUD_PROJECT", raising=False)
    
    with patch("bridge.main.project_from_path", return_value=None):
        push_body = {
            "message": {
                "data": base64.b64encode(b'{"resourceName": "fhir/Observation/123"}').decode("utf-8"),
                "attributes": {},
            }
        }
        response = client.post("/pubsub/push", json=push_body)

    assert response.status_code == 500
    assert response.json() == {"status": "error", "reason": "project_id not found"}

@patch("bridge.main.extract_resource_name", return_value="fhir/Observation/123")
@patch("bridge.main.fetch_fhir", side_effect=Exception("FHIR API Down"))
def test_pubsub_push_fetch_fails(mock_fetch, mock_extract, monkeypatch):
    monkeypatch.setenv("PROJECT_ID", "test-project")
    push_body = {
        "message": {
            "data": base64.b64encode(b'{"resourceName": "fhir/Observation/123"}').decode("utf-8"),
        }
    }
    response = client.post("/pubsub/push", json=push_body)
    assert response.status_code == 500
    assert response.json() == {"status": "error", "reason": "fetch failed: FHIR API Down"}

@patch("bridge.main.extract_resource_name", return_value="fhir/Patient/abc")
@patch("bridge.main.fetch_fhir", return_value={"resourceType": "Patient", "id": "abc"})
def test_pubsub_push_ignored_resource(mock_fetch, mock_extract, monkeypatch):
    monkeypatch.setenv("PROJECT_ID", "test-project")
    push_body = {
        "message": {
            "data": base64.b64encode(b'{"resourceName": "fhir/Patient/abc"}').decode("utf-8"),
        }
    }
    response = client.post("/pubsub/push", json=push_body)
    assert response.status_code == 200
    assert response.json() == {"status": "ignored", "reason": "no mapping"}

@patch("bridge.main.publish")
@patch("bridge.main.fetch_fhir")
@patch("bridge.main.extract_resource_name", return_value="fhir/Observation/final-obs")
def test_pubsub_push_success_final(mock_extract, mock_fetch, mock_publish, monkeypatch):
    monkeypatch.setenv("PROJECT_ID", "test-project")
    monkeypatch.setenv("RESULTS_FINAL_TOPIC", "results.final")
    mock_publish.return_value = "mock-message-id-123"
    fhir_resource = {
        "resourceType": "Observation",
        "id": "final-obs",
        "status": "final",
        "effectiveDateTime": "2025-08-28T00:00:00Z",
        "subject": {"reference": "Patient/p1"},
    }
    mock_fetch.return_value = fhir_resource

    push_body = {
        "message": {
            "data": base64.b64encode(b'{"resourceName": "fhir/Observation/final-obs"}').decode("utf-8"),
        }
    }

    response = client.post("/pubsub/push", json=push_body)

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "published_to": "results.final",
        "project": "test-project",
        "messageId": "mock-message-id-123",
    }
    mock_fetch.assert_called_once_with("fhir/Observation/final-obs")
    mock_publish.assert_called_once()
    
    call_args = mock_publish.call_args
    assert call_args.args[0] == "results.final"
    envelope = call_args.args[1]
    assert envelope["resource_type"] == "Observation"
    assert envelope["topic"] == "results.final"
    assert json.loads(envelope["resource"]) == fhir_resource
    assert call_args.kwargs["project_id"] == "test-project"

@patch("bridge.main.publish")
@patch("bridge.main.fetch_fhir")
@patch("bridge.main.extract_resource_name", return_value="fhir/Observation/prelim-obs")
def test_pubsub_push_success_prelim(mock_extract, mock_fetch, mock_publish, monkeypatch):
    monkeypatch.setenv("PROJECT_ID", "test-project")
    monkeypatch.setenv("RESULTS_PRELIM_TOPIC", "results.prelim")
    mock_publish.return_value = "mock-message-id-456"
    fhir_resource = {
        "resourceType": "Observation",
        "id": "prelim-obs",
        "status": "preliminary",
        "effectiveDateTime": "2025-08-28T01:00:00Z",
        "subject": {"reference": "Patient/p2"},
    }
    mock_fetch.return_value = fhir_resource

    push_body = {
        "message": {
            "data": base64.b64encode(b'{"resourceName": "fhir/Observation/prelim-obs"}').decode("utf-8"),
        }
    }

    response = client.post("/pubsub/push", json=push_body)

    assert response.status_code == 200
    assert response.json()["published_to"] == "results.prelim"
    mock_publish.assert_called_once()
    envelope = mock_publish.call_args.args[1]
    assert envelope["topic"] == "results.prelim"
