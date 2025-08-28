# Hospigen

Hospigen is a data engineering project designed to process and standardize healthcare event data. It provides a foundational pipeline for ingesting raw data (such as FHIR resources), wrapping it in a canonical envelope format, and publishing it to a message queue for downstream consumption.

The core component included is the **Bridge Service**, a FastAPI application that acts as an ingestion point.

## Features

*   **Standardized Event Envelope**: Defines a clear, consistent structure for all healthcare events.
*   **Flexible Ingestion**: The Bridge service can receive data via direct HTTP POST or as a push endpoint for a Google Cloud Pub/Sub subscription.
*   **Idempotent Processing**: The service avoids re-processing messages that are already in the canonical envelope format, preventing processing cycles.
*   **Cloud Native**: Built with containerization in mind for easy deployment to services like Google Cloud Run.
*   **Defined Data Contracts**: Schemas for the event envelope are provided for Avro, BigQuery, and JSON Schema.

## Project Structure

```
hospigen/
├── bridge/           # The Bridge microservice
│   ├── main.py       # FastAPI application logic
│   ├── Dockerfile    # Container definition for deployment
│   └── requirements.txt
├── contracts/        # Data contract definitions
│   ├── schemas/      # Avro, BigQuery, and JSON schemas for the envelope
│   └── samples/      # Sample event and insight JSON files
└── README.md
```

## Getting Started

These instructions will help you get the Bridge service running on your local machine.

### Prerequisites

*   Python 3.11+
*   Google Cloud SDK (for authentication to Pub/Sub)
*   Docker (optional, for containerized execution)

### Configuration

1.  **Environment Variables**:
    Copy the example environment file and customize it for your environment.

    ```sh
    cp .env_example .env
    ```

    Edit `.env` to set your Google Cloud Project ID:

    ```
    GCP_PROJECT=your-gcp-project-id
    GCP_REGION=northamerica-northeast1
    ```

2.  **Output Topic**:
    The Bridge service publishes to a Pub/Sub topic defined by the `OUTPUT_TOPIC` environment variable. It defaults to `projects/hospigen/topics/results.final`. You can override this in your environment or `.env` file.

    ```sh
    export OUTPUT_TOPIC="projects/your-gcp-project-id/topics/your-topic-name"
    ```

    Ensure the topic exists and the service has permissions to publish to it.

### Running Locally

1.  Navigate to the `bridge` directory:
    ```sh
    cd bridge
    ```

2.  Install the required Python packages:
    ```sh
    pip install -r requirements.txt
    ```

3.  Start the FastAPI server:
    ```sh
    uvicorn main:app --reload --port 8080
    ```
    The service will be available at `http://localhost:8080`.

### Running with Docker

1.  Build the Docker image from the project root:
    ```sh
    docker build -t hospigen-bridge -f bridge/Dockerfile .
    ```

2.  Run the container, passing in your environment configuration:
    ```sh
    docker run -p 8080:8080 --env-file .env hospigen-bridge
    ```

## Usage

You can send data to the Bridge service's `/pubsub/push` endpoint.

### Direct POST

You can POST any JSON payload directly. The service will extract the `resource` field if it exists, otherwise it will use the entire payload as the resource to be wrapped in the envelope.

```sh
curl -X POST http://localhost:8080/pubsub/push \
-H "Content-Type: application/json" \
-d @bridge/obs.json
```

### As a Pub/Sub Push Endpoint

The service is designed to work as a push endpoint for a Google Cloud Pub/Sub subscription. It correctly decodes the base64-encoded `data` field from the standard Pub/Sub push message format.

When a message is pushed from a subscription, the service will:
1.  Decode the message payload.
2.  Wrap the payload in the canonical `HospitalGenEnvelope`.
3.  Publish the new enveloped message to the `OUTPUT_TOPIC`.

## Data Contracts

The canonical data format is the `HospitalGenEnvelope`. It standardizes event metadata, provenance, and the raw resource payload. The schemas are defined in the `/contracts/schemas` directory for multiple formats:

*   `envelope.avsc` (Avro)
*   `envelope.bq.json` (BigQuery)
*   `envelope.schema.json` (JSON Schema)