#!/usr/bin/env bash
# reconcile-sweep.sh — decide which previews are dead, from GitHub truth.
#
# Runs IN THE WORKFLOW RUNNER (not on the box): it has the App token and `gh`,
# and it never touches the box. It reads the box census produced by
# reconcile-enumerate.sh and applies the alive-rule from the Preview Lifecycle
# design (https://docs.wilsch-ai.com/global/preview-lifecycle-design, Part 3):
#
#   A preview is ALIVE iff its PR is open AND its branch was pushed within the
#   activity window (default 14 days, push-only heartbeat, operator-tunable).
#   A preview with no open PR dies on the next sweep, without grace.
#
# Only ATTRIBUTABLE previews (checkout-backed, repo+branch both known) are
# candidates for teardown. Anything the census marked as residue is passed
# through untouched — reported, never removed (Part 5: report-not-remove).
#
# Fail-safe: if the consumer repo cannot be resolved under the org, the preview
# is classified `indeterminate` and reported, NOT torn down — the sweep removes
# only what it can positively prove is dead.
#
# Usage:
#   reconcile-sweep.sh <inventory-json-path>
# Env:
#   ORG           GitHub org that owns the consumer repos (e.g. WILSCH-AI-SERVICES)
#   WINDOW_DAYS   activity window in days (default 14)
#   GH_TOKEN      token with read access to the consumer repos (App token)
#   REPORT_FILE   optional path to append a Markdown report (e.g. $GITHUB_STEP_SUMMARY)
#
# Emits the decision as JSON on stdout: { dead:[], alive:[], indeterminate:[], residue:[] }
# Each dead/alive/indeterminate record adds: issue_number, project_path, reason.

set -euo pipefail

INVENTORY="${1:?Usage: reconcile-sweep.sh <inventory-json-path>}"
ORG="${ORG:?Missing ORG}"
WINDOW_DAYS="${WINDOW_DAYS:-14}"

PROJECTS_DIR="$(jq -r '.projects_dir' "$INVENTORY")"
DOMAIN_SUFFIX="$(jq -r '.domain_suffix' "$INVENTORY")"
NOW_EPOCH="$(date -u +%s)"
WINDOW_SECS=$(( WINDOW_DAYS * 86400 ))

log() { echo "$@" >&2; }

# --- Classify one attributable checkout: dead | alive | indeterminate ---
classify() {
    local repo="$1" branch="$2"

    # Repo must resolve under the org, else we cannot prove liveness → keep it.
    if ! gh api "repos/${ORG}/${repo}" >/dev/null 2>&1; then
        echo "indeterminate|repo ${ORG}/${repo} not resolvable — cannot verify PR state"
        return
    fi

    # Open PR with this branch as head, targeting staging.
    # CRITICAL: distinguish a genuine empty result (no PR → dead) from a read
    # FAILURE (403/permission/network). A failure must fail SAFE — keep the
    # preview, mark indeterminate — never be misread as "0 PRs → tear it down".
    local open_prs
    if ! open_prs="$(gh api "repos/${ORG}/${repo}/pulls?state=open&head=${ORG}:${branch}&base=staging" \
                        --jq 'length' 2>/dev/null)"; then
        echo "indeterminate|could not read PRs for ${ORG}/${repo} (token may lack pull_requests:read) — keeping"
        return
    fi
    if [[ "$open_prs" -eq 0 ]]; then
        echo "dead|no open PR for ${branch} → staging"
        return
    fi

    # PR is open — apply the push-window (branch's LAST COMMIT date, not the
    # repo-level pushed_at, which is identical across every branch).
    local last_date last_epoch age_days
    last_date="$(gh api "repos/${ORG}/${repo}/branches/${branch}" \
                    --jq '.commit.commit.committer.date' 2>/dev/null || echo "")"
    if [[ -z "$last_date" ]]; then
        echo "dead|open PR but branch ${branch} has no resolvable head commit"
        return
    fi
    last_epoch="$(date -u -d "$last_date" +%s 2>/dev/null || echo 0)"
    age_days=$(( (NOW_EPOCH - last_epoch) / 86400 ))
    if (( NOW_EPOCH - last_epoch <= WINDOW_SECS )); then
        echo "alive|open PR, pushed ${age_days}d ago (<= ${WINDOW_DAYS}d window)"
    else
        echo "dead|open PR but branch pushed ${age_days}d ago (> ${WINDOW_DAYS}d window)"
    fi
}

dead='[]'; alive='[]'; indeterminate='[]'

while IFS= read -r ck; do
    [[ -n "$ck" ]] || continue
    repo="$(jq -r '.repo' <<<"$ck")"
    branch="$(jq -r '.branch' <<<"$ck")"
    issue_number="$(grep -oiE 'issue-[0-9]+' <<<"$branch" | head -1 | grep -oE '[0-9]+' || true)"
    project_path="${PROJECTS_DIR}/${repo}"

    result="$(classify "$repo" "$branch")"
    status="${result%%|*}"
    reason="${result#*|}"
    log "  ${branch}  ->  ${status}  (${reason})"

    rec="$(jq -c \
        --arg issue "$issue_number" \
        --arg pp "$project_path" \
        --arg reason "$reason" \
        '. + {issue_number:$issue, project_path:$pp, reason:$reason}' <<<"$ck")"

    case "$status" in
        dead)  dead="$(jq -c --argjson r "$rec" '. + [$r]' <<<"$dead")" ;;
        alive) alive="$(jq -c --argjson r "$rec" '. + [$r]' <<<"$alive")" ;;
        *)     indeterminate="$(jq -c --argjson r "$rec" '. + [$r]' <<<"$indeterminate")" ;;
    esac
done < <(jq -c '.checkouts[]' "$INVENTORY")

residue="$(jq -c '.residue' "$INVENTORY")"

decision="$(jq -n \
    --argjson dead "$dead" \
    --argjson alive "$alive" \
    --argjson indeterminate "$indeterminate" \
    --argjson residue "$residue" \
    '{dead:$dead, alive:$alive, indeterminate:$indeterminate, residue:$residue}')"

# --- Human report (Markdown) ---
if [[ -n "${REPORT_FILE:-}" ]]; then
    {
        echo "## Preview reconciliation — ${ORG} (window ${WINDOW_DAYS}d)"
        echo ""
        echo "### 🔻 Dead — to tear down ($(jq '.dead|length' <<<"$decision"))"
        jq -r '.dead[] | "- `\(.branch)` (\(.repo)) — \(.reason) · http \(.http)"' <<<"$decision" || true
        echo ""
        echo "### 🟢 Alive — kept ($(jq '.alive|length' <<<"$decision"))"
        jq -r '.alive[] | "- `\(.branch)` (\(.repo)) — \(.reason)"' <<<"$decision" || true
        echo ""
        echo "### ❓ Indeterminate — kept, needs a look ($(jq '.indeterminate|length' <<<"$decision"))"
        jq -r '.indeterminate[] | "- `\(.branch)` (\(.repo)) — \(.reason)"' <<<"$decision" || true
        echo ""
        echo "### 🧾 Unattributable residue — reported, never removed ($(jq '.residue|length' <<<"$decision"))"
        echo "> Branch-only routes/projects with no per-branch checkout. The repo cannot be"
        echo "> recovered from the name, so the sweep names them for a manual look and leaves them."
        jq -r '.residue[] | "- `\(.branch)` — \(.kind), http \(.http // "n/a") · `\(.path)`"' <<<"$decision" || true
    } >> "$REPORT_FILE"
fi

echo "$decision"
