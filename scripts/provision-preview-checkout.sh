#!/usr/bin/env bash
# provision-preview-checkout.sh — ensure a per-branch STANDALONE checkout exists
# for a preview deploy (issue #2266).
#
# Usage (piped via SSH from deploy-action):
#   bash -s -- <repo-root-path> <preview-path>
#
# Produces a per-branch checkout as a standalone COPY of the repo-root checkout
# already present on the box (`cp -a`), so it carries:
#   - the project's own on-box runtime state (.env, gitignored — a clone would not),
#   - an INDEPENDENT git object store (a full .git copy, not a linked worktree /
#     `gitdir:` pointer into the repo-root).
#
# Additive: never touches the repo-root path. Idempotent: if the preview checkout
# already exists it is left in place (update mode), so a redeploy — or a concurrent
# staging / sibling deploy — leaves a running preview's checkout unchanged
# (containment, AC6). The branch checkout itself is done later by deploy-preview.sh
# operating in this path.
#
# Exit 11 = Level 1 (provisioning) failure — matches preflight's structured level.

set -euo pipefail

REPO_ROOT="${1:?Usage: provision-preview-checkout.sh <repo-root-path> <preview-path>}"
PREVIEW_PATH="${2:?Missing preview-path}"

echo "=== Provisioning per-branch preview checkout ==="

# Distinctness is AC-load-bearing: the preview must never share the repo-root path.
if [[ "$PREVIEW_PATH" == "$REPO_ROOT" ]]; then
    echo "DEPLOY_ERROR:LEVEL=1:DETAIL=preview path equals repo-root path ($REPO_ROOT)" >&2
    exit 11
fi

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "DEPLOY_ERROR:LEVEL=1:DETAIL=repo-root checkout absent at $REPO_ROOT — cannot produce a standalone copy" >&2
    exit 11
fi

if [[ -d "$PREVIEW_PATH" ]]; then
    echo "Preview checkout already present: $PREVIEW_PATH (update mode — left in place)"
else
    echo "Producing standalone copy: $REPO_ROOT -> $PREVIEW_PATH"
    # -a preserves ownership/timestamps and copies .env + the full .git (independent
    # object store). No --reflink games: an independent, self-contained checkout.
    cp -a "$REPO_ROOT" "$PREVIEW_PATH"
    # Register the new path so git ops + preflight's safe.directory check pass.
    git config --global --add safe.directory "$PREVIEW_PATH"
    echo "Standalone copy produced (.env + independent .git carried over)."
fi

echo "Preview checkout ready: $PREVIEW_PATH"
