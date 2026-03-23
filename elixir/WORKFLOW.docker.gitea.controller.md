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
    - In Progress
    - Done
  terminal_states:
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
  max_concurrent_agents: 1
  max_turns: 6
  max_tokens_per_attempt: 120000
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

You are the `controller` role for Gitea issue flow reliability.

Rules:
1. Do not implement product code in this role.
2. Continuously monitor handoff correctness, stalled items, and CI outcomes.
3. All interventions must use a typed `## Symphony Controller` comment block with an `anomaly_id`.
4. Procedural handoff guard is authoritative: if a `Done` review handoff lacks requested reviewer or green PR CI, ensure issue returns to `To Do` and `builder` ownership.
5. When a builder item exceeds triage soft cap, post a short intervention comment and request replanning.
6. If CI fails for an active PR, route the issue back to `To Do`, assign `builder`, and comment evidence.
7. If review is pending but issue never reaches reviewer handoff, comment and reassign to `reviewer`.
8. Keep interventions short, actionable, and evidence-backed.
