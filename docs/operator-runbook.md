# Operator Runbook

This runbook covers both Docker Compose stacks documented in the repository root README:

- single-service: `docker-compose.yml` + `elixir/WORKFLOW.docker.gitea.md`
- role-based: `docker-compose.roles.yml` + role workflows under `elixir/WORKFLOW.docker.gitea.*.md`

Related docs:

- downstream history rewrite recovery: [docs/force-push-window-migration.md](force-push-window-migration.md)

## Quick checks

Start with container state, API state, and the rotating runtime log.

```bash
docker compose ps
curl -fsS http://localhost:4000/api/v1/state | jq
docker compose logs -f symphony
docker compose exec symphony tail -f /var/log/symphony/log/symphony.log
```

Useful paths and endpoints:

- Dashboard: `http://localhost:4000/`
- State API: `http://localhost:4000/api/v1/state`
- Issue API: `http://localhost:4000/api/v1/<issue_identifier>`
- Refresh API: `POST http://localhost:4000/api/v1/refresh`
- Rotating file log in the container: `/var/log/symphony/log/symphony.log`
- Per-issue workspaces in the container: `/workspaces/<issue_identifier>`

Role-based equivalents:

```bash
docker compose -f docker-compose.roles.yml ps
docker compose -f docker-compose.roles.yml logs -f symphony-builder
docker compose -f docker-compose.roles.yml logs -f symphony-reviewer
docker compose -f docker-compose.roles.yml logs -f symphony-triage
docker compose -f docker-compose.roles.yml logs -f symphony-controller
docker compose -f docker-compose.roles.yml exec symphony-builder tail -f /var/log/symphony/log/symphony.log
docker compose -f docker-compose.roles.yml exec symphony-reviewer tail -f /var/log/symphony/log/symphony.log
docker compose -f docker-compose.roles.yml exec symphony-triage tail -f /var/log/symphony/log/symphony.log
docker compose -f docker-compose.roles.yml exec symphony-controller tail -f /var/log/symphony/log/symphony.log
```

## Determine current state

Use `GET /api/v1/state` as the first source of truth.

Symphony is idle when:

- `running` is empty
- `retrying` is empty
- `polling.checking?` flips between `true` and `false` over time

Symphony is active when:

- `running` contains one or more issues
- each running issue shows fields such as `identifier`, `state`, `worker_host`,
  `workspace_path`, `session_id`, `last_codex_event`, `last_codex_timestamp`, and
  `runtime_seconds`

Symphony is failing or degraded when:

- `retrying` is non-empty
- the API is unavailable
- logs repeat fetch, hook, clone, or stall errors

Force a fresh poll if the state looks stale:

```bash
curl -fsS -X POST http://localhost:4000/api/v1/refresh | jq
```

Inspect one issue in detail:

```bash
curl -fsS http://localhost:4000/api/v1/symphony%236 | jq
```

Replace `symphony%236` with the URL-encoded issue identifier you want to inspect.

## Expected lifecycle

For a normal Gitea-backed run, expect this sequence:

1. Symphony polls Gitea for open repository issues and filters to the configured active states and
   assignee.
2. A matching issue is dispatched and usually moved to `In Progress`.
3. Symphony creates `/workspaces/<issue_identifier>`.
4. The `after_create` hook runs `git clone --depth 1 --branch "$SYMPHONY_REPO_BRANCH" "$SYMPHONY_REPO_URL" .`.
5. Codex starts for that workspace. The state API begins showing `session_id`,
   `workspace_path`, `last_codex_event`, and runtime counters.
6. The issue either completes and is closed, or moves into `retrying` with backoff after an error.
7. When an issue reaches a terminal state, Symphony stops active work and cleans up matching
   workspaces.

While that sequence is happening, `docker compose logs -f symphony` should show the dispatch,
workspace hook activity, Codex activity, retries, and terminal outcome.

## Triage

### Auth or clone failures

Symptoms:

- container exits immediately
- `running` briefly appears, then the issue moves to `retrying`
- logs show `missing Codex auth file`, `missing required env var`, `Workspace hook failed`, or
  `Workspace creation failed`

Checks:

```bash
docker compose exec symphony sh -lc 'test -s /root/.codex/auth.json && echo codex-auth-ok'
docker compose exec symphony sh -lc 'env | grep -E "^(GITEA_|SYMPHONY_REPO_)" | sort'
docker compose exec symphony sh -lc 'ls -la /workspaces'
docker compose exec symphony sh -lc 'tail -n 200 /var/log/symphony/log/symphony.log'
```

What to verify:

- `~/.codex/auth.json` is mounted and non-empty
- `.env` includes `GITEA_ENDPOINT`, `GITEA_API_KEY`, `GITEA_OWNER`, `GITEA_REPO`,
  `GITEA_PROJECT_ID`, `SYMPHONY_REPO_URL`, `SYMPHONY_REPO_BRANCH`, and `SYMPHONY_CODEX_COMMAND`
- startup project guard validates `GITEA_PROJECT_ID` via the repo issues page when
  `GITEA_VALIDATE_PROJECT_ID=1` (default)
- `SYMPHONY_REPO_URL` is cloneable from inside the container and the referenced branch exists
- the `after_create` clone command is using credentials that can read the target repo

### Assignment or state mismatch

Symptoms:

- Symphony stays idle even though there is open work
- an issue is visible in Gitea but never appears under `running`
- an already running issue is stopped after a board move or reassignment

Checks:

```bash
curl -fsS http://localhost:4000/api/v1/state | jq
docker compose exec symphony sh -lc 'grep -nE "Dispatching issue|Issue moved to non-active state|Issue no longer routed to this worker" /var/log/symphony/log/symphony.log | tail -n 50'
```

What to verify:

- the issue is in an active board state for this workflow: `To Do` or `In Progress` (builder), or
  `Done` for reviewer, or `Backlog` for triage
- the issue assignee login matches `GITEA_ASSIGNEE`
- the issue is on the configured repository project board, not only open in the issue list
- if board sync is expected, `GITEA_WEB_COOKIE` and `GITEA_WEB_CSRF_TOKEN` are valid

This workflow ignores items in non-active states such as `Backlog`, and it will stop work when an
issue leaves the active state set or is no longer routed to the configured worker assignee.

### Triage metadata block

For token budgeting and queue shaping, triage should maintain a dedicated issue comment block:

```text
## Symphony Triage
estimate_tokens: 80000
soft_cap_tokens: 120000
hard_cap_tokens: 160000
ready: true
```

Runtime behavior:

- `soft_cap_tokens` triggers a one-time warning comment from orchestrator when crossed.
- `hard_cap_tokens` overrides the global per-attempt cap for that issue.
- `ready: true` is the signal for triage to hand off to `To Do` and assign `builder`.

### Controller intervention block

Procedural guardrails and controller interventions should use a typed comment block:

```text
## Symphony Controller
anomaly_id: A04_REVIEW_HANDOFF_MISSING_REVIEWER_REQUEST
detected_at: 2026-03-23T10:11:12Z
issue_identifier: symphony#30
reason: PR #57 does not include reviewer in requested reviewers.
actions_taken: comment, assign:builder, state:To Do
next_owner: builder
expected_recovery: add reviewer request on linked PR and ensure ci/woodpecker/pr/woodpecker is success, then hand off to Done again
```

Use `anomaly_id` to map interventions to the controller anomaly matrix in:
`docs/controller-anomaly-runbook.md`.

### Tracker reachability

Symptoms:

- the API stays up but no fresh work is dispatched
- logs show `Failed to fetch`, `gitea_api_request`, `gitea_api_status`, or board snapshot warnings
- board moves stop working while comment posting or issue closing also starts failing

Checks:

```bash
docker compose exec symphony sh -lc 'curl -fsS -H "Authorization: token $GITEA_API_KEY" "$GITEA_ENDPOINT/api/v1/repos/$GITEA_OWNER/$GITEA_REPO/issues?state=open&limit=1" | jq ".[0].number"'
docker compose exec symphony sh -lc 'curl -fsS "$GITEA_ENDPOINT/$GITEA_OWNER/$GITEA_REPO/projects/$GITEA_PROJECT_ID" >/dev/null && echo board-page-ok'
docker compose exec symphony sh -lc 'tail -n 200 /var/log/symphony/log/symphony.log'
```

What to verify:

- `GITEA_ENDPOINT` resolves from inside the container
- `GITEA_API_KEY` still authorizes REST API calls
- `GITEA_PROJECT_ID` points at the expected project board
- `GITEA_WEB_COOKIE` and `GITEA_WEB_CSRF_TOKEN` are present if you expect board moves

If the REST API call fails, Symphony cannot poll or mutate issues. If only the board page call
fails, polling may still work while board-state mapping and board moves degrade.

## Recovery actions

After fixing configuration or access, use one of these:

```bash
docker compose restart symphony
curl -fsS -X POST http://localhost:4000/api/v1/refresh | jq
```

If a single issue is stuck in retry, inspect its `workspace_path`, review the last log lines for
that issue identifier, and fix the underlying clone/auth/tracker problem before forcing another
poll.
