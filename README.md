# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

### Option 3. Docker Compose quickstart (external Gitea + codex)

This repository includes two Compose paths:

- `docker-compose.yml`: single-service Gitea worker (legacy/simple)
- `docker-compose.roles.yml`: dual-role setup (`builder` + `reviewer`)

Requirements:

- Docker + Docker Compose
- local Codex auth file at `~/.codex/auth.json`
- env files populated from examples (no defaults are assumed)

Run:

Single service:

```bash
cp .env.example .env
docker compose up --build
```

Dual-role services:

```bash
cp .env.builder.example .env.builder
cp .env.reviewer.example .env.reviewer
docker compose -f docker-compose.roles.yml up --build
```

Open the builder dashboard at `http://localhost:4000`.

For live debugging and day-2 operations, see the [operator runbook](docs/operator-runbook.md).

Notes:

- Single-service workflow file: `elixir/WORKFLOW.docker.gitea.md`.
- Dual-role workflow files:
  - `elixir/WORKFLOW.docker.gitea.builder.md`
  - `elixir/WORKFLOW.docker.gitea.reviewer.md`
- Worker workspaces clone from `SYMPHONY_REPO_URL` on `SYMPHONY_REPO_BRANCH`.
- Project board columns should be: `Backlog`, `To Do`, `In Progress`, `Done`.
- The compose stack persists workspaces and logs via named volumes.
- For board-sync/moves, set `GITEA_WEB_COOKIE` and `GITEA_WEB_CSRF_TOKEN` from a logged-in Gitea session.
- Startup validates `GITEA_PROJECT_ID` against the repo issues page by default (`GITEA_VALIDATE_PROJECT_ID=1`).
  - Set `GITEA_VALIDATE_PROJECT_ID=0` only as an emergency bypass.
- Reviewer watchdog fallback is enabled by default (`GITEA_REVIEWER_WATCHDOG=1`): reviewer can pick
  `Done` issues still assigned to `builder` to prevent handoff stalls.
- Terminal label mapping uses stock Gitea labels:
  - `duplicate` => Symphony `Duplicate`
  - `wontfix` => Symphony `Cancelled`
- Board updates use Gitea web routes (session cookie + CSRF), not `/api/v1` PAT endpoints.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
