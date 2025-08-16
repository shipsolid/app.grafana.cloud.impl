# Grafana Cloud Implementations

## Put secrets in GitHub → Settings → Secrets and variables → Actions

**Create .NET OTEL Instrumentation**:
OpenTelemetry instrumentation is the recommended standard to observe applications with Grafana Cloud.
This integration helps you set up the Grafana Agent and .NET auto-instrumentation to send telemetry to Grafana Cloud.

Scope(dotnet):
set:alloy-data-write
  metrics:write
  logs:write
  traces:write
  profiles:write
  fleet-management:read

- GRAFANA_OTLP_ENDPOINT
- GRAFANA_OTLP_USERNAME
- GRAFANA_OTLP_PASSWORD

**Create Hosted Prometheus metrics(Standard via Grafana Alloy)**:
Your Grafana Cloud stack includes a massively scalable, high-performance, and highly available Prometheus endpoint.
Bring together the raw, unsampled metrics for all your applications and infrastructure, spread around the globe, in one place
with 13-months retention (Pro).

- GRAFANA_RW_URL
- GRAFANA_RW_USERNAME
- GRAFANA_RW_PASSWORD

If you run Alloy/your collector directly in a step:

```yml
- name: Run Alloy with secrets
  env:
    GRAFANA_OTLP_USERNAME: ${{ secrets.GRAFANA_OTLP_USERNAME }}
    GRAFANA_OTLP_PASSWORD: ${{ secrets.GRAFANA_OTLP_PASSWORD }}
    GRAFANA_RW_USERNAME:   ${{ secrets.GRAFANA_RW_USERNAME }}
    GRAFANA_RW_PASSWORD:   ${{ secrets.GRAFANA_RW_PASSWORD }}
    # optional if you env-ified URLs
    GRAFANA_OTLP_ENDPOINT: https://otlp-gateway-prod-ca-east-0.grafana.net/otlp
    GRAFANA_RW_URL:        https://prometheus-prod-32-prod-ca-east-0.grafana.net/api/prom/push
  run: |
    ./alloy --server.http.listen-addr=0.0.0.0:12345 \
            --config.file=./path/to/your.river

```

If you run it in Docker:

```yml
- name: Run Alloy container
  run: |
    docker run -d --name alloy --network host \
      -e GRAFANA_OTLP_USERNAME='${{ secrets.GRAFANA_OTLP_USERNAME }}' \
      -e GRAFANA_OTLP_PASSWORD='${{ secrets.GRAFANA_OTLP_PASSWORD }}' \
      -e GRAFANA_RW_USERNAME='${{ secrets.GRAFANA_RW_USERNAME }}' \
      -e GRAFANA_RW_PASSWORD='${{ secrets.GRAFANA_RW_PASSWORD }}' \
      -e GRAFANA_OTLP_ENDPOINT='https://otlp-gateway-prod-ca-east-0.grafana.net/otlp' \
      -e GRAFANA_RW_URL='https://prometheus-prod-32-prod-ca-east-0.grafana.net/api/prom/push' \
      -v "$GITHUB_WORKSPACE/path/to/your.river:/etc/alloy/config.river:ro" \
      grafana/alloy:latest \
      --config.file=/etc/alloy/config.river

```

Local Export envs before running:

```sh
export GRAFANA_OTLP_USERNAME=116
export GRAFANA_OTLP_PASSWORD=glc_...
export GRAFANA_RW_USERNAME=224
export GRAFANA_RW_PASSWORD=glc_...
# optional:
export GRAFANA_OTLP_ENDPOINT=https://otlp-gateway-prod-ca-east-0.grafana.net/otlp
export GRAFANA_RW_URL=https://prometheus-prod-32-prod-ca-east-0.grafana.net/api/prom/push

./alloy --config.file=./config.river

```

## Fake Store Ingestor Runbook

### Create the project & add packages

```sh
dotnet new webapi -n FakeStoreIngestor -f net8.0
cd FakeStoreIngestor

dotnet clean
rd /s /q bin obj   # on mac/linux: rm -rf bin obj

# dotnet add package Microsoft.EntityFrameworkCore.Sqlite
dotnet remove package Pomelo.EntityFrameworkCore.MySql && \
dotnet remove package Microsoft.EntityFrameworkCore.Relational && \
dotnet remove package Microsoft.EntityFrameworkCore.Design && \
dotnet remove package Microsoft.EntityFrameworkCore && \
dotnet remove package Swashbuckle.AspNetCore

dotnet add package Pomelo.EntityFrameworkCore.MySql --version 8.0.3 && \
dotnet add package Microsoft.EntityFrameworkCore --version 8.0.13 && \
dotnet add package Microsoft.EntityFrameworkCore.Relational --version 8.0.13 && \
dotnet add package Microsoft.EntityFrameworkCore.Design --version 8.0.13 && \
dotnet add package Swashbuckle.AspNetCore



.
.
.

dotnet tool install -g dotnet-ef
dotnet ef migrations add InitialCreate
dotnet ef database update

docker run -d --name mysql-fakestore \
  -e MYSQL_ROOT_PASSWORD=secret \
  -e MYSQL_DATABASE=fakestore \
  -e MYSQL_USER=appuser \
  -e MYSQL_PASSWORD=apppass \
  -p 3306:3306 \
  mysql:8.0

dotnet run


# http://localhost:5171/swagger/index.html

# Import first 5
curl -v -X 'POST' \
  'http://localhost:5171/import/5' \
  -H 'accept: */*'

# Read one
curl -X 'GET' \
  'http://localhost:5171/products/1' \
  -H 'accept: */*'

# List all
curl -X 'GET' \
  'http://localhost:5171/products' \
  -H 'accept: */*'


# Build
docker build -t fakestore-api .
docker build --no-cache -t fakestore-api .

DOCKER_BUILDKIT=1 docker build --progress=plain --no-cache -t fakestore-api .
# or disable BuildKit:
DOCKER_BUILDKIT=0 docker build -t fakestore-api -f ... .


# Run against local MySQL and real FakeStore
docker run -p 8080:8080 \
  -e ConnectionStrings__Default="Server=host.docker.internal;Port=3306;Database=fakestore;User=appuser;Password=apppass;TreatTinyAsBoolean=false;DefaultCommandTimeout=30" \
  -e Ingest__BaseUrl="https://fakestoreapi.com/" \
  -e Ingest__ProductsEndpoint="products" \
  fakestore-api

# Test
curl -s http://localhost:8080/health
curl -s -X POST http://localhost:8080/import/5
curl -s http://localhost:8080/products | jq .

```

```yml docker-compose-snippet
services:
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: fakestore
      MYSQL_USER: appuser
      MYSQL_PASSWORD: apppass
    ports: [ "3306:3306" ]

  mock:
    image: node:20-alpine
    working_dir: /data
    command: sh -c "npm i -g json-server@^0 && json-server --host 0.0.0.0 --port 3000 db.json"
    volumes:
      - ./.github/mock/db.json:/data/db.json:ro
    ports: [ "3000:3000" ]

  api:
    image: fakestore-api
    build:
      context: .
      dockerfile: Dockerfile
    environment:
      ASPNETCORE_URLS: http://0.0.0.0:8080
      ConnectionStrings__Default: "Server=mysql;Port=3306;Database=fakestore;User=appuser;Password=apppass;TreatTinyAsBoolean=false;DefaultCommandTimeout=30"
      # switch to mock easily:
      # Ingest__BaseUrl: "http://mock:3000/"
      # Ingest__ProductsEndpoint: "products"
    ports: [ "8080:8080" ]
    depends_on:
      - mysql
      - mock

```

## Image deletion from ghcr.io `.github/workflows/ghcr-cleanup.yml`

Below is a **two-stage GitHub Actions workflow** that:

1. **Previews** what would be deleted (packages & versions), and
2. **Deletes** only if you explicitly confirm via `workflow_dispatch` inputs.

It supports **user or org scope**, optional **package name filter**, **dry-run**, **keep N latest versions**, and **older-than (days)** pruning. Uses a PAT (`GHCR_TOKEN`) with `read:packages` + `delete:packages`.

---

### How to use it

1. Create a PAT with **`read:packages`** and **`delete:packages`** → save it as repo/org secret **`GHCR_TOKEN`**.

2. Commit the workflow.

3. Run **“GHCR Cleanup (Preview & Delete)”** from **Actions → Run workflow**:

   - Set:
     - `scope`: `user` or `org`
     - `owner`: your username or org name
     - `package_filter` (optional substring, e.g., `fakestore-`)
     - `keep_latest` (e.g., `2` to always keep two newest)
     - `older_than_days` (e.g., `14` to delete only if 14+ days old)
     - `dry_run`: `true` to preview
   - Check the **job summary** and the **PREVIEW\.md artifact**.

4. When satisfied, re-run with:

- `dry_run = false`
- `confirm_delete = YES-DELETE`

---

### Common patterns

- **Delete everything (nuclear):** `keep_latest=0`, `older_than_days=0`, `package_filter=""`, `dry_run=false`, `confirm_delete=YES-DELETE`.
- **Keep latest N, remove older ones:** `keep_latest=3`, `older_than_days=0`.
- **Only clean stale stuff:** `keep_latest=0`, `older_than_days=30` (removes versions older than 30 days; keeps newer ones).
- **Target a family:** set `package_filter="myapp-"`.

If you want, I can tailor defaults for **your org/user** and add **branch protections** so only admins can run the delete job.
