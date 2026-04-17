# syntax=docker/dockerfile:1
FROM python:3.11-slim

# ── System dependencies & Microsoft ODBC Driver 18 ──────────────────────────
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        gnupg2 \
        apt-transport-https \
        ca-certificates \
        unixodbc-dev \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] \
        https://packages.microsoft.com/debian/12/prod bookworm main" \
        > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 \
    && rm -rf /var/lib/apt/lists/*

# ── Python dependencies ──────────────────────────────────────────────────────
WORKDIR /app
COPY requirements.txt requirements-web.txt ./
RUN pip install --no-cache-dir -r requirements.txt -r requirements-web.txt

# ── Application code ─────────────────────────────────────────────────────────
COPY . .

EXPOSE 5000

CMD ["python", "webapp/app.py"]
