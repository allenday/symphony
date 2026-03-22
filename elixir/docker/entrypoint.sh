#!/usr/bin/env bash
set -euo pipefail

if [[ ! -s /root/.codex/auth.json ]]; then
  echo "missing Codex auth file at /root/.codex/auth.json" >&2
  echo "mount ~/.codex/auth.json into the container before starting" >&2
  exit 1
fi

required_env=(
  GITEA_ENDPOINT
  GITEA_API_KEY
  GITEA_OWNER
  GITEA_REPO
  GITEA_PROJECT_ID
  SYMPHONY_REPO_URL
  SYMPHONY_REPO_BRANCH
  SYMPHONY_CODEX_COMMAND
)

for key in "${required_env[@]}"; do
  if [[ -z "${!key:-}" ]]; then
    echo "missing required env var: ${key}" >&2
    echo "configure it in .env before starting compose" >&2
    exit 1
  fi
done

mkdir -p /var/log/symphony /workspaces

if [[ "${GITEA_VALIDATE_PROJECT_ID:-1}" != "0" ]]; then
  if [[ -z "${GITEA_WEB_COOKIE:-}" ]]; then
    echo "missing required env var: GITEA_WEB_COOKIE" >&2
    echo "project-id validation needs a logged-in web cookie (or set GITEA_VALIDATE_PROJECT_ID=0 to bypass)" >&2
    exit 1
  fi

  issues_url="${GITEA_ENDPOINT%/}/${GITEA_OWNER}/${GITEA_REPO}/issues"
  project_selector="data-element-id=\"${GITEA_PROJECT_ID}\" data-url=\"/${GITEA_OWNER}/${GITEA_REPO}/issues/projects\""

  if ! issues_html="$(curl -fsSL --cookie "${GITEA_WEB_COOKIE}" "${issues_url}")"; then
    echo "failed to fetch repo issues page for project-id validation: ${issues_url}" >&2
    echo "check GITEA_ENDPOINT, GITEA_WEB_COOKIE, and network reachability" >&2
    exit 1
  fi

  if grep -q 'href="/user/login"' <<<"${issues_html}"; then
    echo "GITEA_WEB_COOKIE appears invalid or expired (redirected to login)" >&2
    echo "refresh GITEA_WEB_COOKIE and GITEA_WEB_CSRF_TOKEN from a live browser session" >&2
    exit 1
  fi

  if ! grep -q "${project_selector}" <<<"${issues_html}"; then
    known_project_ids="$(
      grep -oE "data-element-id=\"[0-9]+\" data-url=\"/${GITEA_OWNER}/${GITEA_REPO}/issues/projects\"" <<<"${issues_html}" \
      | sed -E 's/data-element-id=\"([0-9]+)\".*/\1/' \
      | sort -u \
      | paste -sd ',' -
    )"
    echo "configured GITEA_PROJECT_ID=${GITEA_PROJECT_ID} not found for ${GITEA_OWNER}/${GITEA_REPO}" >&2
    if [[ -n "${known_project_ids}" ]]; then
      echo "detected project ids: ${known_project_ids}" >&2
    else
      echo "no visible project ids detected on issues page" >&2
    fi
    exit 1
  fi
fi

if [[ -n "${CARAPACE_INSTALL_URL:-}" ]]; then
  if [[ ! -x /opt/carapace-venv/bin/gt ]]; then
    python3 -m venv /opt/carapace-venv
    /opt/carapace-venv/bin/pip install --upgrade pip
    /opt/carapace-venv/bin/pip install "${CARAPACE_INSTALL_URL}"
  fi
  export PATH="/opt/carapace-venv/bin:${PATH}"
fi

workflow_file="${SYMPHONY_WORKFLOW_FILE:-/opt/symphony/elixir/WORKFLOW.docker.gitea.md}"

exec ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root /var/log/symphony \
  --port 4000 \
  "${workflow_file}"
