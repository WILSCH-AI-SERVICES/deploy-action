#!/usr/bin/env bash
# deploy-preview.sh — Deploy or update a preview environment.
#
# Usage (piped via SSH from deploy-action):
#   bash -s -- <project-path> <branch> <domain-suffix>
#
# Convention-driven:
#   - Entry service discovered from deploy.entry label (value = container port)
#   - Two-phase auto-detected: docker-compose.infra.yml exists → infra shared, app isolated
#   - Ports auto-assigned (all _PORT env vars zeroed for isolation)
#   - Volumes cloned from staging (skipped in update mode)
#   - 5-level back pressure: L0 convention → L1 preflight → L2 config → L3 health → L4 access
#   - Structured exit codes: 12=L2, 13=L3, 14=L4 (L0/L1 handled by validator/preflight.sh)
#   - DEPLOY_ERROR transport: script echoes DEPLOY_ERROR:LEVEL=N:DETAIL=... before exit

set -euo pipefail

# --- Arguments ---
PROJECT_PATH="${1:?Usage: deploy-preview.sh <project-path> <branch> <domain-suffix>}"
BRANCH="${2:?Missing branch}"
DOMAIN_SUFFIX="${3:?Missing domain-suffix}"

cd "$PROJECT_PATH"

# --- Git auth: HTTPS + ephemeral token (falls back to SSH remote if unset) ---
if [[ -n "${GIT_TOKEN:-}" && -n "${GIT_REPO:-}" ]]; then
    git remote set-url origin "https://x-access-token:${GIT_TOKEN}@github.com/${GIT_REPO}.git"
fi

# --- Configuration ---
CADDY_CONF_DIR="/etc/caddy/conf.d"
COMPOSE_FILE="docker-compose.yml"
INFRA_COMPOSE_FILE="docker-compose.infra.yml"

# Sanitize branch → project name (lowercase, alphanum + hyphens)
PROJECT_NAME=$(echo "$BRANCH" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

# --- Git: fetch and checkout branch ---
echo "=== Fetching branch: $BRANCH ==="
git fetch origin
git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH"
git pull origin "$BRANCH"

# =================================================================
# Level 2: Validate compose config
# =================================================================
echo ""
echo "=== Level 2: Validating compose config ==="
if ! COMPOSE_ERR=$(docker compose config --quiet 2>&1); then
    echo "DEPLOY_ERROR:LEVEL=2:DETAIL=compose config invalid: ${COMPOSE_ERR}" >&2
    exit 12
fi
echo "Compose config valid."

# --- Detect staging project name ---
STAGING_PROJECT=$(docker compose config --format json | jq -r '.name')
if [[ -z "$STAGING_PROJECT" || "$STAGING_PROJECT" == "null" ]]; then
    echo "DEPLOY_ERROR:LEVEL=2:DETAIL=cannot detect staging project name from $COMPOSE_FILE" >&2
    exit 12
fi

# Guard: preview must not collide with staging
if [[ "$PROJECT_NAME" == "$STAGING_PROJECT" ]]; then
    echo "DEPLOY_ERROR:LEVEL=2:DETAIL=branch resolves to staging project name '$STAGING_PROJECT'" >&2
    exit 12
fi

# --- Detect update vs fresh deploy ---
UPDATE_MODE=false
if COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker compose ps --quiet 2>/dev/null | grep -q .; then
    echo "Preview '$PROJECT_NAME' already running — update mode."
    UPDATE_MODE=true
fi

echo "Staging project: $STAGING_PROJECT"
echo "Preview project: $PROJECT_NAME"

# --- Discover entry service from deploy.entry label ---
# Label value = container port (e.g., deploy.entry: "3080")
ENTRY_INFO=$(docker compose config --format json | jq -r '
  .services | to_entries[] |
  select(.value.labels["deploy.entry"] // empty) |
  "\(.key) \(.value.labels["deploy.entry"])"
')
if [[ -z "$ENTRY_INFO" ]]; then
    echo "DEPLOY_ERROR:LEVEL=2:DETAIL=no service with deploy.entry label in $COMPOSE_FILE" >&2
    exit 12
fi
ENTRY_SERVICE=$(echo "$ENTRY_INFO" | head -1 | awk '{print $1}')
ENTRY_PORT=$(echo "$ENTRY_INFO" | head -1 | awk '{print $2}')
echo "Entry service: $ENTRY_SERVICE (container port: $ENTRY_PORT)"

# --- Detect two-phase (infra compose exists) ---
TWO_PHASE=false
COMPOSE_ARGS=(-f "$COMPOSE_FILE")
if [[ -f "$INFRA_COMPOSE_FILE" ]]; then
    TWO_PHASE=true
    echo "Two-phase detected: $INFRA_COMPOSE_FILE exists"
    # Preview connects to staging's infra network (shared Ollama, TEI, Langfuse)
    INFRA_NET="${STAGING_PROJECT}-infra"
    OVERRIDE_FILE="/tmp/${PROJECT_NAME}-network-override.yml"
    cat > "$OVERRIDE_FILE" <<YAML
networks:
  infra:
    name: ${INFRA_NET}
    external: true
YAML
    COMPOSE_ARGS+=(-f "$OVERRIDE_FILE")
fi

# --- Named volumes from compose ---
mapfile -t VOLUMES < <(docker compose config --format json | jq -r '.volumes | keys[]')
echo "Volumes: ${VOLUMES[*]}"

# --- Zero all port env vars for preview isolation ---
for var in $(grep -oP '\$\{[A-Z_]+_PORT' "$COMPOSE_FILE" | sed 's/\${//' | sort -u); do
    export "${var}=0"
done

# --- Trap: cleanup on failure ---
CLEANUP_NEEDED=false
cleanup_on_failure() {
    if [[ "$CLEANUP_NEEDED" == "true" ]]; then
        echo ""
        echo "ERROR: Deployment failed, cleaning up orphaned resources..." >&2
        COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker compose "${COMPOSE_ARGS[@]}" down --remove-orphans 2>/dev/null || true
        if [[ "$UPDATE_MODE" == "false" ]]; then
            for vol in "${VOLUMES[@]}"; do
                docker volume rm "${PROJECT_NAME}_${vol}" 2>/dev/null || true
            done
        fi
        sudo rm -f "${CADDY_CONF_DIR}/${PROJECT_NAME}.conf" 2>/dev/null || true
        sudo caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
        echo "Cleanup complete." >&2
    fi
}
trap cleanup_on_failure EXIT

# =================================================================
# Clone volumes (skip in update mode)
# =================================================================
CLEANUP_NEEDED=true
if [[ "$UPDATE_MODE" == "false" ]]; then
    echo ""
    echo "=== Cloning volumes ==="
    for vol in "${VOLUMES[@]}"; do
        src="${STAGING_PROJECT}_${vol}"
        dst="${PROJECT_NAME}_${vol}"

        if ! docker volume inspect "$src" &>/dev/null; then
            echo "  WARNING: Source volume '$src' not found — creating empty '$dst'"
            docker volume create "$dst" >/dev/null
            continue
        fi

        docker volume create "$dst" >/dev/null
        echo "  Cloning $src → $dst ..."
        docker run --rm -v "${src}:/src:ro" -v "${dst}:/dst" alpine cp -a /src/. /dst/
    done
    echo "Volumes cloned."
else
    echo ""
    echo "=== Skipping volume clone (update mode) ==="
fi

# =================================================================
# Level 3: Start services + wait for health
# =================================================================
echo ""
echo "=== Level 3: Starting services (waiting for health) ==="
if ! COMPOSE_PROJECT_NAME="$PROJECT_NAME" \
    docker compose "${COMPOSE_ARGS[@]}" up -d --wait --pull always; then
    echo "DEPLOY_ERROR:LEVEL=3:DETAIL=service health check failed" >&2
    exit 13
fi

echo "All services healthy."

# =================================================================
# Query entry service auto-assigned port
# =================================================================
ASSIGNED_PORT=$(COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker compose "${COMPOSE_ARGS[@]}" port "$ENTRY_SERVICE" "$ENTRY_PORT" | cut -d: -f2)
echo "Entry port assigned: $ASSIGNED_PORT"

# =================================================================
# Caddy reverse proxy
# =================================================================
echo ""
echo "=== Configuring Caddy ==="
PREVIEW_DOMAIN="${PROJECT_NAME}.${DOMAIN_SUFFIX}"

cat <<CADDYEOF | sudo tee "${CADDY_CONF_DIR}/${PROJECT_NAME}.conf" >/dev/null
${PREVIEW_DOMAIN} {
    reverse_proxy localhost:${ASSIGNED_PORT}
}
CADDYEOF

sudo caddy reload --config /etc/caddy/Caddyfile
echo "Caddy configured for ${PREVIEW_DOMAIN}"

# =================================================================
# Level 4: Verify external access (fatal with retries)
# =================================================================
echo ""
echo "=== Level 4: Verifying external access ==="
for i in 1 2 3; do
    if curl -sf --max-time 10 "https://${PREVIEW_DOMAIN}" >/dev/null 2>&1; then
        echo "Preview accessible at https://${PREVIEW_DOMAIN}"
        break
    fi
    if [[ $i -eq 3 ]]; then
        echo "DEPLOY_ERROR:LEVEL=4:DETAIL=preview not accessible at https://${PREVIEW_DOMAIN} after 3 retries" >&2
        exit 14
    fi
    echo "  Attempt $i/3 — waiting for TLS/DNS..."
    sleep 5
done

# =================================================================
# Success — disarm cleanup trap
# =================================================================
CLEANUP_NEEDED=false
trap - EXIT

echo ""
echo "==========================================="
echo "  Preview deployed successfully"
echo "==========================================="
echo "  URL:     https://${PREVIEW_DOMAIN}"
echo "  Project: $PROJECT_NAME"
echo "  Port:    $ASSIGNED_PORT"
echo "  Cleanup: Uses deploy-action with action=cleanup-preview"
echo "==========================================="
