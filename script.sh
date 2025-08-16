#!/usr/bin/env bash
set -euo pipefail

### --- Temp ---
# docker rm -f fakestore-api && \
# docker rmi -f ghcr.io/shipsolid/fakestore-api:latest
# docker pull --platform=linux/amd64 ghcr.io/shipsolid/fakestore-api:latest
# docker pull ghcr.io/shipsolid/fakestore-api:latest


# docker rm -f fakestore-mock && \
# docker rmi -f ghcr.io/shipsolid/fakestore-mock:latest
# docker pull --platform=linux/amd64 ghcr.io/shipsolid/fakestore-mock:latest

# docker rm -f alloy-agent && \
# docker rmi -f ghcr.io/shipsolid/myalloy:latest
# docker pull --platform=linux/amd64 ghcr.io/shipsolid/myalloy:latest

### --- Config (override via environment) ---
NETWORK="${NETWORK:-observability}"

# GHCR auth (optional but recommended if your images are private)
GHCR_USER="${GHCR_USER:-${USER:-ghcr}}"
GHCR_TOKEN="${GHCR_TOKEN:-}"           # e.g., a PAT with read:packages
GHCR_OWNER="${GHCR_OWNER:-shipsolid}"  # e.g., your GitHub org/user

# Images
IMG_MYSQL="${IMG_MYSQL:-mysql:8.4}"
IMG_CURL="curlimages/curl:8.8.0"
IMG_BUSYBOX="busybox:1.36"
IMG_FAKESTORE_MOCK="${IMG_FAKESTORE_MOCK:-ghcr.io/shipsolid/fakestore-mock:latest}"
IMG_FAKESTORE_API="${IMG_FAKESTORE_API:-ghcr.io/${GHCR_OWNER}/fakestore-api:latest}"
IMG_ALLOY="${IMG_ALLOY:-ghcr.io/${GHCR_OWNER}/myalloy:latest}"

# MySQL settings
MYSQL_DB="${MYSQL_DB:-fakestore}"
MYSQL_USER_APP="${MYSQL_USER_APP:-appuser}"
MYSQL_PASS_APP="${MYSQL_PASS_APP:-apppass}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-rootpass}"

# API settings
ASPNETCORE_URLS="${ASPNETCORE_URLS:-http://0.0.0.0:5171/}"
CONN_STR_DEFAULT="${CONN_STR_DEFAULT:-Server=mysql;Port=3306;Database=${MYSQL_DB};User=${MYSQL_USER_APP};Password=${MYSQL_PASS_APP};TreatTinyAsBoolean=false;DefaultCommandTimeout=30}"
INGEST_BASE_URL="${INGEST_BASE_URL:-http://fakestore-mock:3000/}"
INGEST_PRODUCTS_ENDPOINT="${INGEST_PRODUCTS_ENDPOINT:-products}"

# Grafana Alloy (REQUIRED for Alloy to send data)
GRAFANA_OTLP_ENDPOINT="${GRAFANA_OTLP_ENDPOINT:-}"
GRAFANA_OTLP_USERNAME="${GRAFANA_OTLP_USERNAME:-}"
GRAFANA_OTLP_PASSWORD="${GRAFANA_OTLP_PASSWORD:-}"
GRAFANA_RW_URL="${GRAFANA_RW_URL:-}"
GRAFANA_RW_USERNAME="${GRAFANA_RW_USERNAME:-}"
GRAFANA_RW_PASSWORD="${GRAFANA_RW_PASSWORD:-}"

# Timeouts / retries
RETRIES="${RETRIES:-40}"
SLEEP_SECS="${SLEEP_SECS:-2}"
METRICS_MAX_TRIES="${METRICS_MAX_TRIES:-600}"  # 600 * 2s = 20 minutes

### --- Helpers ---
log() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 127; }
}

cleanup() {
  log "Stopping containers..."
  docker rm -f alloy-agent fakestore-api fakestore-mock mysql >/dev/null 2>&1 || true
}
trap 'echo; log "Script failed — dumping logs for context"; dump_logs || true' ERR

dump_logs() {
  echo "::group::Docker logs alloy-agent"
  docker logs alloy-agent || true
  echo "::endgroup::"

  echo "::group::Docker logs fakestore-api"
  docker logs fakestore-api || true
  echo "::endgroup::"

  echo "::group::Check Products from API (via Docker network)"
  docker run --rm --network "$NETWORK" "$IMG_CURL" \
    curl -sSf http://fakestore-api:5171/products || true
  echo "::endgroup::"

  echo "::group::DNS & TCP sanity"
  docker run --rm --network "$NETWORK" "$IMG_BUSYBOX" nslookup fakestore-api || true
  docker run --rm --network "$NETWORK" "$IMG_CURL" \
    curl -sS -o /dev/null fakestore-api:5171 || true
  echo "::endgroup::"

  echo "::group::Check /metrics headers"
  docker run --rm --network "$NETWORK" "$IMG_CURL" \
    curl -sS -D - -o /dev/null http://fakestore-api:5171/metrics || true
  echo "::endgroup::"
}

wait_for_http() {
  local url="$1"
  local name="$2"
  local tries="${3:-$RETRIES}"
  local sleep_s="${4:-$SLEEP_SECS}"

  for i in $(seq 1 "$tries"); do
    if curl -sf "$url" > /dev/null; then
      log "$name is up!"
      return 0
    fi
    log "Waiting for $name ($i/$tries)..."
    sleep "$sleep_s"
  done
  return 1
}

wait_for_http_in_net() {
  local net="$1" url="$2" name="$3"
  local tries="${4:-$RETRIES}" sleep_s="${5:-$SLEEP_SECS}"

  for i in $(seq 1 "$tries"); do
    if docker run --rm --network "$net" "$IMG_CURL" curl -sf "$url" > /dev/null; then
      log "$name is up!"
      return 0
    fi
    log "Waiting for $name ($i/$tries)..."
    sleep "$sleep_s"
  done
  return 1
}

### --- Pre-flight ---
require_cmd docker
log "Docker OK"

# Optional GHCR login
if [[ -n "$GHCR_TOKEN" ]]; then
  log "Logging into ghcr.io as $GHCR_USER"
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
else
  log "GHCR_TOKEN not set — skipping docker login"
fi

# Create network if not exists
if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  log "Creating network: $NETWORK"
  docker network create "$NETWORK" >/dev/null
else
  log "Network $NETWORK already exists"
fi

### --- Start MySQL ---
log "Starting MySQL..."
docker rm -f mysql >/dev/null 2>&1 || true
docker volume rm -f mysql-data >/dev/null 2>&1 || true
docker volume create mysql-data >/dev/null

docker run -d --name mysql \
  --network "$NETWORK" \
  -p 3306:3306 \
  -v mysql-data:/var/lib/mysql \
  -e MYSQL_DATABASE="$MYSQL_DB" \
  -e MYSQL_USER="$MYSQL_USER_APP" \
  -e MYSQL_PASSWORD="$MYSQL_PASS_APP" \
  -e MYSQL_ROOT_PASSWORD="$MYSQL_ROOT_PASS" \
  "$IMG_MYSQL" >/dev/null

# Wait for MySQL from inside the container
for i in $(seq 1 "$RETRIES"); do
  if docker exec mysql mysqladmin ping -h127.0.0.1 -u"$MYSQL_USER_APP" -p"$MYSQL_PASS_APP" --silent; then
    log "MySQL is up!"
    break
  fi
  log "Waiting for MySQL ($i/$RETRIES)..."
  sleep "$SLEEP_SECS"
  if [[ "$i" -eq "$RETRIES" ]]; then
    echo "MySQL failed to start; printing logs"
    docker logs mysql || true
    exit 1
  fi
done

### --- Start fakestore-mock ---
log "Starting fakestore-mock..."
docker rm -f fakestore-mock >/dev/null 2>&1 || true
docker run -d --name fakestore-mock \
  --network "$NETWORK" \
  -p 3000:3000 \
  "$IMG_FAKESTORE_MOCK" >/dev/null

wait_for_http_in_net "$NETWORK" "http://fakestore-mock:3000/products" "fakestore-mock" 60 "$SLEEP_SECS" || {
  echo "fakestore-mock failed to start; printing logs"
  docker logs fakestore-mock || true
  exit 1
}

### --- Start fakestore-api ---
log "Starting fakestore-api..."
docker rm -f fakestore-api >/dev/null 2>&1 || true
docker run -d --name fakestore-api \
  --network "$NETWORK" \
  -p 5171:5171 \
  -e ASPNETCORE_URLS="$ASPNETCORE_URLS" \
  -e ConnectionStrings__Default="$CONN_STR_DEFAULT" \
  -e Ingest__BaseUrl="$INGEST_BASE_URL" \
  -e Ingest__ProductsEndpoint="$INGEST_PRODUCTS_ENDPOINT" \
  --health-cmd='wget -qO- http://fakestore-api:5171/products || exit 1' \
  --health-interval=30s \
  --health-timeout=3s \
  --health-start-period=20s \
  --health-retries=3 \
  "$IMG_FAKESTORE_API" >/dev/null

# Wait for API via host (since we published the port)
wait_for_http "http://127.0.0.1:5171/products" "fakestore-api" "$RETRIES" "$SLEEP_SECS" || {
  echo "API failed to start; printing logs"
  docker logs fakestore-api || true
  exit 1
}

### --- Start Grafana Alloy (optional if creds provided) ---
if [[ -n "$GRAFANA_OTLP_ENDPOINT" && -n "$GRAFANA_OTLP_USERNAME" && -n "$GRAFANA_OTLP_PASSWORD" && -n "$GRAFANA_RW_URL" && -n "$GRAFANA_RW_USERNAME" && -n "$GRAFANA_RW_PASSWORD" ]]; then
  log "Starting Alloy agent..."
  # mask sensitive outputs
  echo "::add-mask::$GRAFANA_OTLP_PASSWORD" || true
  echo "::add-mask::$GRAFANA_RW_PASSWORD" || true

  docker rm -f alloy-agent >/dev/null 2>&1 || true
  docker run -d --name alloy-agent \
    --network "$NETWORK" \
    -e GRAFANA_OTLP_ENDPOINT="$GRAFANA_OTLP_ENDPOINT" \
    -e GRAFANA_OTLP_USERNAME="$GRAFANA_OTLP_USERNAME" \
    -e GRAFANA_OTLP_PASSWORD="$GRAFANA_OTLP_PASSWORD" \
    -e GRAFANA_RW_URL="$GRAFANA_RW_URL" \
    -e GRAFANA_RW_USERNAME="$GRAFANA_RW_USERNAME" \
    -e GRAFANA_RW_PASSWORD="$GRAFANA_RW_PASSWORD" \
    "$IMG_ALLOY" >/dev/null

  wait_for_http_in_net "$NETWORK" "http://alloy-agent:12345/health" "Alloy agent" "$RETRIES" "$SLEEP_SECS" || {
    echo "Alloy agent failed to start; printing logs"
    docker logs alloy-agent || true
    exit 1
  }
else
  log "Alloy credentials not fully provided — skipping Alloy startup."
fi

### --- Quick API tests ---
log "API test: import 5 products"
curl -sS -X POST 'http://127.0.0.1:5171/import/5' -H 'accept: */*' || true

log "API test: get product 1"
curl -sS 'http://127.0.0.1:5171/products/1' | jq . || true

log "API test: list first 5 products"
curl -sS 'http://127.0.0.1:5171/products' | jq '.[0:5]' || true

### --- Dump logs & checks ---
dump_logs

### --- Wait for /metrics (via Docker network) ---
log "Waiting for /metrics via Docker network..."
URL="http://fakestore-api:5171/metrics"
docker run --rm --network "$NETWORK" "$IMG_CURL" -sS -D - -o /dev/null "$URL" || true

for i in $(seq 1 "$METRICS_MAX_TRIES"); do
  CODE="$(docker run --rm --network "$NETWORK" "$IMG_CURL" -s -o /dev/null -w '%{http_code}' "$URL" || echo 000)"
  if [[ "$CODE" == "200" ]]; then
    log "✅ /metrics ready (HTTP 200) on attempt $i"
    exit 0
  fi
  log "⏳ /metrics not ready yet (HTTP $CODE) — attempt $i/$METRICS_MAX_TRIES"
  sleep "$SLEEP_SECS"
done

echo "❌ /metrics never reached 200 — dumping API logs"
docker logs fakestore-api || true
exit 1
