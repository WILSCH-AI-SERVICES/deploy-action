#!/usr/bin/env bash
# preflight.sh — Level 1 server pre-flight checks before any deploy action.
#
# Usage (piped via SSH from deploy-action):
#   bash -s -- <project-path>
#
# Checks: deploy user ownership, git safe.directory, Docker daemon, .env presence.
# Fails fast with specific remediation steps before any containers are started.
# Exit code 11 = Level 1 failure (structured exit codes: 10=L0, 11=L1, 12=L2, 13=L3, 14=L4).

set -euo pipefail

PROJECT_PATH="${1:?Usage: preflight.sh <project-path>}"
ERRORS=0

echo "=== Level 1: Server pre-flight checks ==="

# 1. Project directory exists and is owned by deploy
if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "FAIL: Project path does not exist: $PROJECT_PATH"
    echo "  Fix: mkdir -p $PROJECT_PATH && chown deploy:deploy $PROJECT_PATH"
    ERRORS=$((ERRORS + 1))
elif [[ "$(stat -c '%U' "$PROJECT_PATH" 2>/dev/null || stat -f '%Su' "$PROJECT_PATH")" != "deploy" ]]; then
    echo "FAIL: Project not owned by deploy user: $PROJECT_PATH"
    echo "  Fix: sudo chown -R deploy:deploy $PROJECT_PATH"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: Project directory exists and owned by deploy"
fi

# 2. Git safe.directory configured
if ! git config --global --get-all safe.directory 2>/dev/null | grep -qF "$PROJECT_PATH"; then
    echo "FAIL: git safe.directory not set for $PROJECT_PATH"
    echo "  Fix: git config --global --add safe.directory $PROJECT_PATH"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: git safe.directory configured"
fi

# 3. Docker daemon accessible
if ! docker info &>/dev/null; then
    echo "FAIL: Docker daemon not running or deploy user lacks docker group"
    echo "  Fix: sudo systemctl start docker && sudo usermod -aG docker deploy"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: Docker daemon accessible"
fi

# 4. .env file present
if [[ ! -f "$PROJECT_PATH/.env" ]]; then
    echo "FAIL: .env file missing at $PROJECT_PATH/.env"
    echo "  Fix: Create .env with required environment variables"
    ERRORS=$((ERRORS + 1))
else
    echo "  OK: .env file present"
fi

if [[ $ERRORS -gt 0 ]]; then
    echo ""
    echo "DEPLOY_ERROR:LEVEL=1:DETAIL=$ERRORS pre-flight check(s) failed" >&2
    echo "ABORT: $ERRORS pre-flight check(s) failed — fix before deploying"
    exit 11
fi

echo ""
echo "All pre-flight checks passed."
