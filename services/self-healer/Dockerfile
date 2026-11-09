FROM python:3.12-slim AS builder

WORKDIR /src
COPY requirements.txt .

RUN python -m venv /venv && \
    /venv/bin/pip install --no-cache-dir --upgrade pip && \
    /venv/bin/pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim

RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -u 1000 -m appuser
WORKDIR /app

COPY --from=builder /venv /venv
COPY app.py .

ENV PATH="/venv/bin:$PATH"

USER appuser
EXPOSE 8080

# 1 worker: o cooldown por deployment fica em memória e precisa ser único.
CMD ["opentelemetry-instrument", "gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "4", "app:app"]
