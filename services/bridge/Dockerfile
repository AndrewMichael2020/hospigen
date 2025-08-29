# Simple, works on Cloud Build/Run
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PORT=8080

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . /app

# Cloud Run will pass $PORT
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
