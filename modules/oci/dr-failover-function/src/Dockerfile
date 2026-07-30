# OCI Functions Python runtime Dockerfile
# Uses official Python base image with OCI Functions SDK

FROM python:3.11-slim

WORKDIR /function

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy function code
COPY func.py func.yaml ./

# Create non-root user for security
RUN useradd -m -u 1000 fnuser && chown -R fnuser:fnuser /function
USER fnuser

# Set entrypoint for OCI Functions (fdk handles the HTTP server)
ENTRYPOINT ["fdk", "/function/func.py", "handler"]
