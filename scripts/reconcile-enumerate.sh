#!/usr/bin/env bash
# reconcile-enumerate.sh — read-only census of preview state on the deploy box.
#
# Usage (piped via SSH from the reconcile-previews workflow):
#   bash -s -- <projects-dir> <caddy-conf-dir> <domain-suffix>
#
# Emits a single JSON object to stdout describing what the box is actually
# running, split into two kinds:
#
#   checkouts[]  — ATTRIBUTABLE previews. A per-branch standalone checkout
#                  <projects-dir>/<repo>-<branch> (issue #2266 convention).
#                  Both the consumer repo AND the branch are recoverable from
#                  the directory name, so the sweep can ask GitHub whether this
#                  preview is still alive and, if not, tear it down.
#
#   residue[]    — UNATTRIBUTABLE preview-pattern leftovers: a Caddy
#                  <branch>.conf route or a compose project named after a
#                  branch with NO matching per-branch checkout. The repo cannot
#                  be recovered from a branch-only name, so the sweep REPORTS
#                  these and never removes them (design: report-not-remove).
#
# READ-ONLY: this script inspects; it never stops a container, edits a route,
# or deletes a path. All teardown is done later by cleanup-preview.sh against
# the checkouts[] the runner classifies as dead.
#
# Requires jq (already present on the box — cleanup-preview.sh depends on it).

set -euo pipefail

PROJECTS_DIR="${1:?Usage: reconcile-enumerate.sh <projects-dir> <caddy-conf-dir> <domain-suffix>}"
CADDY_CONF_DIR="${2:?Missing caddy-conf-dir}"
DOMAIN_SUFFIX="${3:?Missing domain-suffix}"

# --- Helper: live HTTP status of a preview domain (0 on no-answer) ---
http_status() {
    curl -sk -o /dev/null -w '%{http_code}' --max-time 6 "https://$1" 2>/dev/null || echo "000"
}

# --- Helper: is a compose project of this name currently running? ---
# Matches deploy-preview.sh: preview project name == sanitized branch.
compose_running() {
    docker compose ls --all --format json 2>/dev/null \
        | jq -e --arg n "$1" 'map(select(.Name == $n)) | length > 0' >/dev/null 2>&1
}

# =====================================================================
# 1. Attributable previews — per-branch standalone checkouts
#    A preview checkout is <repo-root>-<branch> where branch == issue-*.
#    A staging root (e.g. 01_ARCHIBUS__archibus-fm-assistant) has no
#    "-issue-" infix and is therefore never treated as a preview.
# =====================================================================
checkouts_json='[]'
shopt -s nullglob
for dir in "$PROJECTS_DIR"/*-issue-*; do
    [[ -d "$dir" ]] || continue
    base="$(basename "$dir")"
    # Split on the FIRST "-issue-": repo is the prefix, branch is issue-<rest>.
    repo="${base%%-issue-*}"
    branch="issue-${base#*-issue-}"
    [[ -n "$repo" && "$repo" != "$base" ]] || continue

    conf_path="${CADDY_CONF_DIR}/${branch}.conf"
    domain="${branch}.${DOMAIN_SUFFIX}"

    conf_exists=false;   [[ -f "$conf_path" ]] && conf_exists=true
    running=false;       compose_running "$branch" && running=true

    rec="$(jq -n \
        --arg repo "$repo" \
        --arg branch "$branch" \
        --arg checkout "$dir" \
        --arg domain "$domain" \
        --arg http "$(http_status "$domain")" \
        --argjson conf_exists "$conf_exists" \
        --argjson running "$running" \
        '{repo:$repo, branch:$branch, checkout:$checkout, domain:$domain,
          http:$http, conf_exists:$conf_exists, compose_running:$running}')"
    checkouts_json="$(jq -c --argjson r "$rec" '. + [$r]' <<<"$checkouts_json")"
done

# Set of branches that ARE backed by a checkout — used to exclude them from
# residue (their routes/compose belong to an attributable preview).
backed_branches="$(jq -r '.[].branch' <<<"$checkouts_json" | sort -u)"
is_backed() { grep -qxF "$1" <<<"$backed_branches"; }

# =====================================================================
# 2. Unattributable residue — Caddy issue-*.conf routes with no checkout
# =====================================================================
residue_json='[]'
for conf in "$CADDY_CONF_DIR"/issue-*.conf; do
    [[ -f "$conf" ]] || continue
    branch="$(basename "$conf" .conf)"
    is_backed "$branch" && continue          # belongs to an attributable preview
    domain="${branch}.${DOMAIN_SUFFIX}"
    rec="$(jq -n \
        --arg kind "caddy-route" \
        --arg branch "$branch" \
        --arg path "$conf" \
        --arg domain "$domain" \
        --arg http "$(http_status "$domain")" \
        '{kind:$kind, branch:$branch, path:$path, domain:$domain, http:$http}')"
    residue_json="$(jq -c --argjson r "$rec" '. + [$r]' <<<"$residue_json")"
done

# =====================================================================
# 3. Unattributable residue — compose projects named issue-* with no checkout
# =====================================================================
while IFS= read -r proj; do
    [[ -n "$proj" ]] || continue
    is_backed "$proj" && continue
    rec="$(jq -n --arg kind "compose-project" --arg branch "$proj" \
        '{kind:$kind, branch:$branch, path:"(docker compose project)", domain:null, http:null}')"
    residue_json="$(jq -c --argjson r "$rec" '. + [$r]' <<<"$residue_json")"
done < <(docker compose ls --all --format json 2>/dev/null \
            | jq -r '.[].Name | select(startswith("issue-"))' 2>/dev/null || true)

# =====================================================================
# Emit the census
# =====================================================================
jq -n \
    --arg projects_dir "$PROJECTS_DIR" \
    --arg caddy_dir "$CADDY_CONF_DIR" \
    --arg domain_suffix "$DOMAIN_SUFFIX" \
    --argjson checkouts "$checkouts_json" \
    --argjson residue "$residue_json" \
    '{projects_dir:$projects_dir, caddy_dir:$caddy_dir, domain_suffix:$domain_suffix,
      checkouts:$checkouts, residue:$residue}'
