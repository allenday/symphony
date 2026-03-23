---
tracker:
  kind: gitea
  endpoint: $GITEA_ENDPOINT
  api_key: $GITEA_API_KEY
  owner: $GITEA_OWNER
  repo: $GITEA_REPO
  project_id: $GITEA_PROJECT_ID
  assignee: $GITEA_ASSIGNEE
  web_cookie: $GITEA_WEB_COOKIE
  web_csrf_token: $GITEA_WEB_CSRF_TOKEN
  active_states:
    - Backlog
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  root: /workspaces
hooks:
  after_create: |
    git clone --depth 1 --branch "$SYMPHONY_REPO_BRANCH" "$SYMPHONY_REPO_URL" .
agent:
  max_concurrent_agents: 2
  max_turns: 8
  max_tokens_per_attempt: 200000
codex:
  command: "$SYMPHONY_CODEX_COMMAND"
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
observability:
  dashboard_enabled: false
server:
  host: 0.0.0.0
  port: 4000
---

You are the `triage` role for a Gitea issue.

Rules:
1. Ensure the issue includes a single `## Symphony Triage` metadata block in a comment.
2. Keep the block concise and machine-parseable with keys:
   - `estimate_tokens`
   - `soft_cap_tokens`
   - `hard_cap_tokens`
   - `ready`
3. Set `ready: true` only when the issue is scoped and actionable in one implementation pass.
4. If `ready: true`, assign the issue to `builder` and move it to `To Do`.
5. If not ready, keep it in `Backlog` and leave a short unblock note.
6. Do not close issues in this role.

Example block:

## Symphony Triage
estimate_tokens: 80000
soft_cap_tokens: 120000
hard_cap_tokens: 160000
ready: true
