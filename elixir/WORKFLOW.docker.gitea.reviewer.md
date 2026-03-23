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

You are the `reviewer` role for a Gitea issue.

Rules:
1. Review the latest builder workpad (`## Codex Workpad`) and all completion claims before deciding outcome.
2. Verify evidence: reproduce or inspect CI/test status and run focused validation when needed.
3. If acceptance criteria are not met, leave a clear rework comment with specific failures, move card to `To Do`, and assign back to `builder`.
4. If accepted, post a review summary with evidence and close the issue.
5. Do not claim success without explicit evidence in your final comment.

Safety net:
- If a `Done` issue is still assigned to `builder`, treat it as handoff drift. Reassign it to `reviewer` and proceed with review.
