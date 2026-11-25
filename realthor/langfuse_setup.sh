
#!/usr/bin/env sh

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
LF_DIR="$DIR/langfuse"

# Network configuration
WEB_PORT="${LANGFUSE_WEB_PORT:-13000}"
MINIO_PORT="${LANGFUSE_MINIO_PORT:-19090}"

HOST="http://localhost:$WEB_PORT"
MINIO_HOST="http://localhost:$MINIO_PORT"

PUBLIC_KEY="pk-lf-realthor0000000000000000"
SECRET_KEY="sk-lf-realthor0000000000000000"

MAX_WAIT=300
FRESH=0

for arg in "$@"; do
    [ "$arg" = "--fresh" ] && FRESH=1
done

# Update an environment variable without deleting other settings.
set_env() {
    file="$1"
    key="$2"
    value="$3"

    [ -f "$file" ] || touch "$file"

    awk -v key="$key" \
        'index($0, key "=") != 1' "$file" > "$file.tmp"

    printf '%s=%s\n' "$key" "$value" >> "$file.tmp"
    mv "$file.tmp" "$file"
}

# Clone Langfuse if necessary.
if [ ! -d "$LF_DIR" ]; then
    echo "Cloning Langfuse (v3.130.0)..."

    git clone --depth 1 --branch v3.130.0 \
        https://github.com/langfuse/langfuse.git "$LF_DIR"
fi

# Keep configuration separate from upstream Compose.
cat > "$LF_DIR/docker-compose.override.yml" <<'EOF'
services:
  langfuse-web:
    ports: !override
      - "127.0.0.1:${LANGFUSE_WEB_PORT:-13000}:3000"

  langfuse-worker:
    ports: !reset []

  clickhouse:
    ports: !reset []

  postgres:
    ports: !reset []

  redis:
    ports: !reset []

  minio:
    image: cgr.dev/chainguard/minio:latest
    ports: !override
      - "127.0.0.1:${LANGFUSE_MINIO_PORT:-19090}:9000"
EOF

# Preserve existing Langfuse environment settings.
LF_ENV="$LF_DIR/.env"

set_env "$LF_ENV" LANGFUSE_WEB_PORT "$WEB_PORT"
set_env "$LF_ENV" LANGFUSE_MINIO_PORT "$MINIO_PORT"
set_env "$LF_ENV" NEXTAUTH_URL "$HOST"
set_env "$LF_ENV" LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT "$MINIO_HOST"
set_env "$LF_ENV" LANGFUSE_S3_BATCH_EXPORT_EXTERNAL_ENDPOINT "$MINIO_HOST"

# Headless project initialization.
set_env "$LF_ENV" LANGFUSE_INIT_ORG_ID realthor
set_env "$LF_ENV" LANGFUSE_INIT_ORG_NAME RealThor
set_env "$LF_ENV" LANGFUSE_INIT_PROJECT_ID realthor
set_env "$LF_ENV" LANGFUSE_INIT_PROJECT_NAME RealThor
set_env "$LF_ENV" LANGFUSE_INIT_PROJECT_PUBLIC_KEY "$PUBLIC_KEY"
set_env "$LF_ENV" LANGFUSE_INIT_PROJECT_SECRET_KEY "$SECRET_KEY"
set_env "$LF_ENV" LANGFUSE_INIT_USER_EMAIL demo@realthor.local
set_env "$LF_ENV" LANGFUSE_INIT_USER_PASSWORD realthor-demo
set_env "$LF_ENV" LANGFUSE_INIT_USER_NAME "RealThor Demo"

# Optional: disable telemetry.
set_env "$LF_ENV" TELEMETRY_ENABLED false

cd "$LF_DIR"

echo "Validating Docker Compose configuration..."
docker compose config --quiet

if [ "$FRESH" = "1" ]; then
    echo "Wiping existing Langfuse data..."
    docker compose down -v
fi

echo "Starting Langfuse..."
docker compose up -d

echo ""
echo "Container status:"
docker compose ps

# Check readiness with a bounded timeout.
echo ""
echo "Waiting for Langfuse at $HOST..."

START_TIME=$(date +%s)

until curl -fsS --max-time 5 \
    "$HOST/api/public/health" >/dev/null 2>&1; do

    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))

    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        echo ""
        echo "ERROR: Langfuse startup timed out."

        docker compose ps -a
        docker compose logs --tail=50

        exit 1
    fi

    printf "Waiting... %ss / %ss\r" "$ELAPSED" "$MAX_WAIT"
    sleep 5
done

echo ""
echo "Langfuse health check passed."

# Write application credentials without deleting other settings.
ENV="$DIR/.env"

set_env "$ENV" LANGFUSE_PUBLIC_KEY "$PUBLIC_KEY"
set_env "$ENV" LANGFUSE_SECRET_KEY "$SECRET_KEY"
set_env "$ENV" LANGFUSE_HOST "$HOST"

echo ""
echo "Langfuse is ready."
echo "Dashboard: $HOST"
echo "MinIO API: $MINIO_HOST"
echo "Email: demo@realthor.local"
echo "Password: realthor-demo"
echo "Application keys written to $ENV"
echo ""
echo "To stop without deleting data:"
echo "  cd langfuse && docker compose down"
