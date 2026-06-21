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

# --- Error transport: emit DEPLOY_ERROR before exit on failure ---
CURRENT_LEVEL=2
CURRENT_DETAIL="staging deploy failed"
trap 'echo "DEPLOY_ERROR:LEVEL=${CURRENT_LEVEL}:DETAIL=${CURRENT_DETAIL}" >&2; exit $((CURRENT_LEVEL + 10))' ERR

cd "$PROJECT_PATH"

# --- Git auth: HTTPS + ephemeral token (falls back to SSH remote if unset) ---
if [[ -n "${GIT_TOKEN:-}" && -n "${GIT_REPO:-}" ]]; then
    git remote set-url origin "https://x-access-token:${GIT_TOKEN}@github.com/${GIT_REPO}.git"
fi

# --- Configuration ---
INFRA_COMPOSE_FILE="docker-compose.infra.yml"

echo "=== Deploying to staging ==="
echo "Project: $PROJECT_PATH"

# --- Git: ensure on staging and pull latest ---
CURRENT_LEVEL=2; CURRENT_DETAIL="git pull failed"
echo ""
echo "=== Pulling latest code ==="
git fetch origin
# Always deploy from staging — preview deploys may have switched the branch.
# No stderr swallow: a dirty or failed checkout must surface, not silently leave
# HEAD on a preview branch (the #922 shared-checkout contamination).
git checkout staging || git checkout -b staging origin/staging
git pull origin staging
echo "Branch: staging (updated)"

# --- Source-isolation guard (#922) ---
# PROJECT_PATH is keyed on repo, not branch, so preview and staging share one
# on-disk checkout. A concurrent preview deploy can leave this dir on the wrong
# branch — without this gate a stale checkout ships under a green GHA run. That
# silent contamination is what invalidated the org-revert MCP validation in
# #2076/#2087. Assert the triggering commit is actually reachable from HEAD on
# staging; otherwise fail loudly instead of deploying stale code.
if [[ -n "${GITHUB_SHA:-}" ]]; then
    CURRENT_LEVEL=2
    ON_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    CURRENT_DETAIL="source-isolation (#922): on branch '${ON_BRANCH}', triggering commit ${GITHUB_SHA:0:7} not reachable from HEAD $(git rev-parse --short HEAD) — shared checkout served stale/wrong code"
    # Spring the ERR trap (→ DEPLOY_ERROR:LEVEL=2, exit 12) unless we are on
    # staging AND the triggering commit is an ancestor of HEAD. A bare `&&` would
    # be exempt from set -e on its left operand, so the not-on-staging case is
    # made explicit here.
    if [[ "$ON_BRANCH" != "staging" ]] || ! git merge-base --is-ancestor "$GITHUB_SHA" HEAD; then
        false
    fi
    echo "Source-isolation guard passed: HEAD on staging includes ${GITHUB_SHA:0:7}."
fi

# --- Two-phase detection ---
if [[ -f "$INFRA_COMPOSE_FILE" ]]; then
    CURRENT_LEVEL=3; CURRENT_DETAIL="infra service health check failed"
    echo ""
    echo "=== Phase 1: Updating infra services ==="
    docker compose -f "$INFRA_COMPOSE_FILE" up -d --wait --pull always
    echo "Infra services healthy."
fi

CURRENT_LEVEL=3; CURRENT_DETAIL="app service health check failed"
echo ""
echo "=== Phase 2: Updating app services ==="
docker compose up -d --wait --build --pull always
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
