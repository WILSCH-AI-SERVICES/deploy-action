#!/usr/bin/env bash
# deploy-staging.sh — Deploy to staging environment.
#
# Usage (piped via SSH from deploy-action):
#   bash -s -- <project-path> <domain-suffix>
#
# Two-phase auto-detected: if docker-compose.infra.yml exists, updates infra
# first (with health wait) then app. No volume cloning — staging is persistent.

set -euo pipefail

# --- Arguments ---
PROJECT_PATH="${1:?Usage: deploy-staging.sh <project-path> <domain-suffix>}"
DOMAIN_SUFFIX="${2:?Missing domain-suffix}"

cd "$PROJECT_PATH"

# --- Configuration ---
INFRA_COMPOSE_FILE="docker-compose.infra.yml"

echo "=== Deploying to staging ==="
echo "Project: $PROJECT_PATH"

# --- Git: pull latest ---
echo ""
echo "=== Pulling latest code ==="
git fetch origin
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git pull origin "$CURRENT_BRANCH"
echo "Branch: $CURRENT_BRANCH (updated)"

# --- Two-phase detection ---
if [[ -f "$INFRA_COMPOSE_FILE" ]]; then
    echo ""
    echo "=== Phase 1: Updating infra services ==="
    docker compose -f "$INFRA_COMPOSE_FILE" up -d --wait --pull always
    echo "Infra services healthy."
fi

echo ""
echo "=== Phase 2: Updating app services ==="
docker compose up -d --wait --pull always
echo "App services healthy."

# --- Verify all services ---
echo ""
echo "=== Verifying staging health ==="
RUNNING=$(docker compose ps --status running --quiet 2>/dev/null | wc -l | tr -d ' ')
EXPECTED=$(docker compose config --format json | jq '[.services | keys[]] | length')

if [[ "$RUNNING" -eq "$EXPECTED" ]]; then
    echo "App: $RUNNING/$EXPECTED services running."
else
    echo "WARNING: App: $RUNNING/$EXPECTED services running." >&2
fi

if [[ -f "$INFRA_COMPOSE_FILE" ]]; then
    INFRA_RUNNING=$(docker compose -f "$INFRA_COMPOSE_FILE" ps --status running --quiet 2>/dev/null | wc -l | tr -d ' ')
    INFRA_EXPECTED=$(docker compose -f "$INFRA_COMPOSE_FILE" config --format json | jq '[.services | keys[]] | length')
    if [[ "$INFRA_RUNNING" -eq "$INFRA_EXPECTED" ]]; then
        echo "Infra: $INFRA_RUNNING/$INFRA_EXPECTED services running."
    else
        echo "WARNING: Infra: $INFRA_RUNNING/$INFRA_EXPECTED services running." >&2
    fi
fi

echo ""
echo "==========================================="
echo "  Staging deployed successfully"
echo "==========================================="
