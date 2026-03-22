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
    - To Do
    - In Progress
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
  max_turns: 10
  max_tokens_per_attempt: 400000
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

You are working on a Gitea issue.

Use issue comments as the execution log and close issues when complete.
