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
    echo "refresh GITEA_WEB_COOKIE from a live browser session" >&2
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

  if [[ -n "${GITEA_USERNAME:-}" ]]; then
    user_api_url="${GITEA_ENDPOINT%/}/api/v1/user"
    if ! user_api_json="$(
      curl -fsSL \
        -H "Authorization: token ${GITEA_API_KEY}" \
        "${user_api_url}"
    )"; then
      echo "failed to query token identity from ${user_api_url}" >&2
      echo "check GITEA_API_KEY and network reachability" >&2
      exit 1
    fi

    token_login="$(
      sed -n 's/.*"login":"\([^"]*\)".*/\1/p' <<<"${user_api_json}" | head -n1
    )"

    if [[ -z "${token_login}" ]]; then
      echo "unable to parse token identity login from /api/v1/user response" >&2
      exit 1
    fi

    if [[ "${token_login}" != "${GITEA_USERNAME}" ]]; then
      echo "GITEA_USERNAME does not match token identity" >&2
      echo "configured GITEA_USERNAME=${GITEA_USERNAME}, token login=${token_login}" >&2
      exit 1
    fi
  fi

  project_url="${GITEA_ENDPOINT%/}/${GITEA_OWNER}/${GITEA_REPO}/projects/${GITEA_PROJECT_ID}"
  if ! project_html="$(curl -fsSL --cookie "${GITEA_WEB_COOKIE}" "${project_url}")"; then
    echo "failed to fetch project page for CSRF validation: ${project_url}" >&2
    exit 1
  fi

  if grep -q 'href="/user/login"' <<<"${project_html}"; then
    echo "GITEA_WEB_COOKIE appears invalid on project page (redirected to login)" >&2
    exit 1
  fi

  csrf_token="$(
    sed -n 's/.*_csrf=\([^;[:space:]]*\).*/\1/p' <<<"${GITEA_WEB_COOKIE}" | head -n1
  )"
  if [[ -z "${csrf_token}" ]]; then
    echo "GITEA_WEB_COOKIE is missing _csrf; cannot validate project mutation" >&2
    exit 1
  fi

  mapfile -t project_column_ids < <(
    grep -oE 'class="project-column"[^>]*data-id="[0-9]+"' <<<"${project_html}" \
      | sed -E 's/.*data-id="([0-9]+)".*/\1/'
  )

  if [[ ${#project_column_ids[@]} -eq 0 ]]; then
    echo "no project columns detected on ${project_url}; cannot validate board mutation" >&2
    exit 1
  fi

  columns_payload='{"columns":['
  for i in "${!project_column_ids[@]}"; do
    column_id="${project_column_ids[$i]}"
    [[ $i -gt 0 ]] && columns_payload+=","
    columns_payload+="{\"columnID\":${column_id},\"sorting\":${i}}"
  done
  columns_payload+=']}'

  move_url="${project_url}/move"
  tmp_body="$(mktemp)"
  http_code="$(
    curl -sS -o "${tmp_body}" -w "%{http_code}" \
      -X POST \
      -H "content-type: application/json" \
      -H "x-csrf-token: ${csrf_token}" \
      --cookie "${GITEA_WEB_COOKIE}" \
      --data "${columns_payload}" \
      "${move_url}"
  )"

  if [[ ! "${http_code}" =~ ^2 ]]; then
    echo "Gitea web mutation validation failed at startup: ${move_url}" >&2
    echo "HTTP ${http_code}: $(tr '\n' ' ' <"${tmp_body}" | sed 's/[[:space:]]\+/ /g')" >&2
    echo "refresh GITEA_WEB_COOKIE (with current _csrf) and restart" >&2
    rm -f "${tmp_body}"
    exit 1
  fi
  rm -f "${tmp_body}"
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
