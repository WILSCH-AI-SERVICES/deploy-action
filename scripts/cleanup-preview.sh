#!/usr/bin/env bash
# cleanup-preview.sh — Tear down a preview environment.
#
# Usage (piped via SSH from deploy-action):
#   bash -s -- <project-path> <branch> <domain-suffix>
#
# Removes preview containers, branch-scoped volumes, and Caddy config.
# Verifies staging health after teardown.

set -euo pipefail

# --- Arguments ---
PROJECT_PATH="${1:?Usage: cleanup-preview.sh <project-path> <branch> <domain-suffix>}"
BRANCH="${2:?Missing branch}"
DOMAIN_SUFFIX="${3:?Missing domain-suffix}"

# --- Error transport: emit CLEANUP_ERROR before exit on failure ---
CURRENT_DETAIL="cleanup failed"
trap 'echo "CLEANUP_ERROR:DETAIL=${CURRENT_DETAIL}" >&2; exit 1' ERR

# --- Configuration ---
CADDY_CONF_DIR="/etc/caddy/conf.d"
COMPOSE_FILE="docker-compose.yml"
INFRA_COMPOSE_FILE="docker-compose.infra.yml"

# Must match deploy-preview.sh sanitization
PROJECT_NAME=$(echo "$BRANCH" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

# #2266: the preview ran from its own per-branch STANDALONE checkout, distinct
# from the repo-root path. Derive it the same way deploy.yml provisioned it, tear
# down from there, and remove it on teardown. Fall back to the repo-root path for
# the `down` only if the per-branch checkout is already gone.
PREVIEW_PATH="${PROJECT_PATH}-${PROJECT_NAME}"
if [[ -d "$PREVIEW_PATH" ]]; then
    cd "$PREVIEW_PATH"
else
    cd "$PROJECT_PATH"
fi

echo "Cleaning up preview: $PROJECT_NAME"

# --- Detect two-phase for compose args ---
COMPOSE_ARGS=(-f "$COMPOSE_FILE")
if [[ -f "$INFRA_COMPOSE_FILE" ]]; then
    STAGING_PROJECT=$(docker compose config --format json 2>/dev/null | jq -r '.name')
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

# =================================================================
# Stop containers and remove branch-scoped volumes
# =================================================================
CURRENT_DETAIL="docker compose down failed for ${PROJECT_NAME}"
echo ""
echo "=== Stopping services ==="
if COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker compose "${COMPOSE_ARGS[@]}" ps --quiet 2>/dev/null | grep -q .; then
    COMPOSE_PROJECT_NAME="$PROJECT_NAME" docker compose "${COMPOSE_ARGS[@]}" down -v --remove-orphans
    echo "Services stopped, volumes removed."
else
    echo "No running services found for project '$PROJECT_NAME'."
    # Attempt orphaned volume cleanup
    mapfile -t VOLUMES < <(docker compose config --format json | jq -r '.volumes | keys[]')
    for vol in "${VOLUMES[@]}"; do
        docker volume rm "${PROJECT_NAME}_${vol}" 2>/dev/null || true
    done
fi

# =================================================================
# Remove Caddy config and reload
# =================================================================
CURRENT_DETAIL="caddy config removal failed for ${PROJECT_NAME}"
echo ""
echo "=== Removing Caddy config ==="
CONF_FILE="${CADDY_CONF_DIR}/${PROJECT_NAME}.conf"
if [[ -f "$CONF_FILE" ]]; then
    sudo rm "$CONF_FILE"
    sudo caddy reload --config /etc/caddy/Caddyfile
    echo "Caddy config removed and reloaded."
else
    echo "No Caddy config found at $CONF_FILE (already clean)."
fi

# =================================================================
# Remove the per-branch standalone checkout (#2266)
# =================================================================
CURRENT_DETAIL="preview checkout removal failed for ${PREVIEW_PATH}"
echo ""
echo "=== Removing preview checkout ==="
# Leave the current (soon-to-be-deleted) dir before removing it; the staging
# health check below must run from the repo-root checkout, not the preview copy.
cd "$PROJECT_PATH"
if [[ -d "$PREVIEW_PATH" && "$PREVIEW_PATH" != "$PROJECT_PATH" ]]; then
    rm -rf "$PREVIEW_PATH"
    echo "Removed preview checkout: $PREVIEW_PATH"
else
    echo "No preview checkout at $PREVIEW_PATH (already clean)."
fi

# =================================================================
# Verify staging health
# =================================================================
echo ""
echo "=== Verifying staging health ==="
RUNNING_COUNT=$(docker compose ps --status running --quiet 2>/dev/null | wc -l | tr -d ' ')
EXPECTED_COUNT=$(docker compose config --format json | jq '[.services | keys[]] | length')

if [[ "$RUNNING_COUNT" -eq "$EXPECTED_COUNT" ]]; then
    echo "Staging: $RUNNING_COUNT/$EXPECTED_COUNT services running."
else
    echo "WARNING: Staging: $RUNNING_COUNT/$EXPECTED_COUNT services running." >&2
    echo "  Verify manually: docker compose ps" >&2
fi

# =================================================================
# Verify preview URL no longer routes
# =================================================================
PREVIEW_DOMAIN="${PROJECT_NAME}.${DOMAIN_SUFFIX}"
if curl -sf --max-time 5 "https://${PREVIEW_DOMAIN}" >/dev/null 2>&1; then
    echo "WARNING: https://${PREVIEW_DOMAIN} still responding — check Caddy config" >&2
else
    echo "Confirmed: https://${PREVIEW_DOMAIN} no longer routes."
fi

echo ""
echo "==========================================="
echo "  Preview '$PROJECT_NAME' fully removed"
echo "==========================================="
