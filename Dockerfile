FROM python:3.11-slim-bookworm

# Patch OS-level CVEs and install system deps required by native packages + curl for healthcheck
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    gcc g++ libgomp1 curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy requirements first so pip install is cached across rebuilds
COPY requirements-prod.txt .
RUN pip install --no-cache-dir --prefer-binary -r requirements-prod.txt

# Pre-download the FlashRank ONNX model during build to eliminate first-query cold latency
RUN python -c "from flashrank import Ranker; Ranker(cache_dir='/tmp/flashrank')"

# Copy application source code
COPY app/ ./app/

# Port & Runtime environment configuration
ENV PORT=8080
ENV PYTHONUNBUFFERED=1

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:${PORT:-8080}/health || exit 1

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080}"]
