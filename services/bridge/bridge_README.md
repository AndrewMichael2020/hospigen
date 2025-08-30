# Hospigen Bridge Service

## Overview

The Hospigen Bridge is a FastAPI microservice designed to act as an intelligent routing layer between Google Cloud FHIR Store and a domain-driven Pub/Sub messaging architecture.

Its primary responsibilities are:
1.  Listen for change notifications from a Google Cloud FHIR store (delivered via a Pub/Sub push subscription).
2.  Fetch the full FHIR resource that was created or updated.
3.  Analyze the resource's type and content to determine its business significance.
4.  Wrap the resource in a standardized event "envelope".
5.  Publish this envelope to a specific, downstream Pub/Sub topic corresponding to the business event.

This decouples the raw data persistence events in the FHIR store from the business-level event streams that other services consume.

## How It Works

1.  A FHIR resource is created or updated in a configured Google Cloud FHIR Store.
2.  The FHIR Store publishes a notification message to a Pub/Sub topic. This message's data is a base64-encoded string containing the full name of the FHIR resource (e.g., `projects/my-proj/locations/us-central1/datasets/my-ds/fhirStores/my-fs/fhir/Observation/12345`).
3.  A Pub/Sub push subscription forwards this message as a `POST` request to the bridge's `/pubsub/push` endpoint.
4.  The bridge decodes the message, extracts the FHIR resource name, and calls the Google Cloud Healthcare API to fetch the full JSON representation of the resource.
5.  The bridge evaluates the resource against a series of routing rules (see **Routing Rules** below).
6.  If a rule matches, the bridge constructs a standard **Event Envelope** and publishes it to the appropriate downstream topic.
7.  If no rules match, the event is ignored and a `200 OK` is returned to prevent Pub/Sub from retrying the message.

## Endpoints

### `GET /health`

A simple health check endpoint.
*   **Success Response:** `200 OK` with a JSON body `{"status": "ok"}`.

### `POST /pubsub/push`

The main ingress endpoint for receiving messages from a Pub/Sub push subscription.

*   **Input:** Standard Pub/Sub Push message format.
*   **Success Responses:**
    *   `200 OK` `{"status": "ok", "published_to": "...", "messageId": "..."}`: The message was successfully processed, routed, and published.
    *   `200 OK` `{"status": "ignored", "reason": "..."}`: The message was processed, but no routing rule matched.
    *   `200 OK` `{"status": "skipped"}`: The incoming message was already an envelope and was ignored to prevent loops.
*   **Error Responses:**
    *   `400 Bad Request`: The incoming request body was not valid JSON or was missing required fields.
    *   `500 Internal Server Error`: An error occurred while fetching the FHIR resource or publishing the downstream event.

## Event Envelope

All messages published by the bridge conform to the following JSON structure:

```json
{
  "event_id": "string",
  "topic": "string",
  "occurred_at": "string (ISO 8601)",
  "published_at": "string (ISO 8601)",
  "patient_ref": "string | null",
  "resource_type": "string",
  "resource_id": "string",
  "resource": "string (JSON-stringified FHIR resource)",
  "provenance": {
    "source_system": "string",
    "logic_id": "string",
    "inputs_span": "string",
    "trace": "null"
  }
}
```

## Routing Rules

| FHIR Resource Type         | Conditions                                                              | Destination Topic Env Var      |
| -------------------------- | ----------------------------------------------------------------------- | ------------------------------ |
| `Observation`              | Category is `laboratory` and status is `final`.                         | `RESULTS_FINAL_TOPIC`          |
| `Observation`              | Category is `laboratory` and status is not `final`.                     | `RESULTS_PRELIM_TOPIC`         |
| `Observation`              | Category is `vital-signs` or code is a known vital sign LOINC.          | `RPM_OBS_CREATED_TOPIC`        |
| `ServiceRequest`           | -                                                                       | `ORDERS_CREATED_TOPIC`         |
| `MedicationRequest`        | -                                                                       | `MEDS_ORDERED_TOPIC`           |
| `MedicationAdministration` | -                                                                       | `MEDS_ADMINISTERED_TOPIC`      |
| `Procedure`                | -                                                                       | `PROCEDURES_PERFORMED_TOPIC`   |
| `DocumentReference`        | -                                                                       | `NOTES_CREATED_TOPIC`          |
| `Appointment`              | Status is `booked`, `pending`, `arrived`, etc.                          | `SCHEDULING_CREATED_TOPIC`     |
| `Encounter`                | Class is `EMER` (Emergency) and status is `arrived`.                    | `ED_TRIAGE_TOPIC`              |
| `Encounter`                | Class is `IMP` (Inpatient) and status is `in-progress` or `arrived`.    | `ADT_ADMIT_TOPIC`              |
| `Encounter`                | Class is `IMP` (Inpatient) and this is an update to an existing record. | `ADT_TRANSFER_TOPIC`           |
| `Encounter`                | Class is `IMP` (Inpatient) and status is `finished`.                    | `ADT_DISCHARGE_TOPIC`          |

## Configuration

The service is configured via environment variables.

| Variable                     | Description                                            | Default Value             |
| ---------------------------- | ------------------------------------------------------ | ------------------------- |
| `PROJECT_ID`                 | The Google Cloud Project ID.                           | (auto-detected)           |
| `GOOGLE_CLOUD_PROJECT`       | Alternative for `PROJECT_ID`.                          | (auto-detected)           |
| `LOGIC_ID`                   | Identifier for this service version in the envelope.   | `bridge.router.v4`        |
| `RESULTS_PRELIM_TOPIC`       | Topic for preliminary lab results.                     | `results.prelim`          |
| `RESULTS_FINAL_TOPIC`        | Topic for final lab results.                           | `results.final.v1`        |
| `ORDERS_CREATED_TOPIC`       | Topic for new orders.                                  | `orders.created`          |
| `MEDS_ORDERED_TOPIC`         | Topic for new medication orders.                       | `meds.ordered`            |
| `MEDS_ADMINISTERED_TOPIC`    | Topic for medication administrations.                  | `meds.administered`       |
| `PROCEDURES_PERFORMED_TOPIC` | Topic for performed procedures.                        | `procedures.performed`    |
| `NOTES_CREATED_TOPIC`        | Topic for new clinical notes.                          | `notes.created`           |
| `SCHEDULING_CREATED_TOPIC`   | Topic for new/updated appointments.                    | `scheduling.created`      |
| `ED_TRIAGE_TOPIC`            | Topic for emergency department triage events.          | `ed.triage`               |
| `ADT_ADMIT_TOPIC`            | Topic for patient admission events.                    | `adt.admit`               |
| `ADT_TRANSFER_TOPIC`         | Topic for patient transfer events.                     | `adt.transfer`            |
| `ADT_DISCHARGE_TOPIC`        | Topic for patient discharge events.                    | `adt.discharge`           |
| `RPM_OBS_CREATED_TOPIC`      | Topic for remote patient monitoring (vitals) events.   | `rpm.observation.created` |

## Local Development

1.  **Install dependencies:**
    ```bash
    pip install -r requirements.txt
    ```

2.  **Set Environment Variables:**
    Export the necessary environment variables listed in the configuration table, for example:
    ```bash
    export PROJECT_ID="your-gcp-project-id"
    export RESULTS_FINAL_TOPIC="dev-results-final"
    # ... and so on
    ```

3.  **Run the server:**
    The application uses `uvicorn` to run.
    ```bash
    uvicorn bridge.main:app --reload --port 8080
    ```

4.  **Authenticate with GCP:**
    For local development, ensure your environment is authenticated to Google Cloud.
    ```bash
    gcloud auth application-default login
    ```
