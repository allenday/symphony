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

You are the `builder` role for a Gitea issue.

Rules:
1. Start by posting or updating a single workpad comment (marker: `## Codex Workpad`) with your plan and live progress.
2. Move the issue to `In Progress` when implementation starts.
3. Implement the change in code, run relevant checks, and include concrete evidence (test command + result) in the workpad.
4. Never close the issue in this role.
5. Before moving to `Done`, explicitly assign the issue to `reviewer` and ensure the linked PR has `reviewer` in `requested_reviewers`.
6. Do not hand off to `Done` until required PR CI (`ci/woodpecker/pr/woodpecker`) is green.
7. When done, add a completion summary comment with evidence, move the card to `Done`, and leave it open for reviewer validation.
8. If blocked, keep issue open, explain the blocker with evidence, and request human help in a comment.
