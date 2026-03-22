# Gitea External Compose Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace memory quickstart with an external Gitea-backed quickstart using strict `.env` configuration and add a minimal Gitea tracker adapter.

**Architecture:** Add a new `tracker.kind: gitea` path that talks to Gitea REST issue APIs (`/api/v1/repos/{owner}/{repo}/issues`) for polling, comments, and state updates. Since this Gitea instance exposes no project-board API endpoints, state persistence uses issue open/closed plus labels (`duplicate`, `wontfix`) for terminal reasons, while board columns remain an operational convention. Compose passes all Gitea config through `.env` with no defaults.

**Tech Stack:** Elixir, Req HTTP client, Docker Compose, Gitea REST API.

### Task 1: Add Gitea tracker backend

**Files:**
- Create: `elixir/lib/symphony_elixir/gitea/client.ex`
- Create: `elixir/lib/symphony_elixir/gitea/adapter.ex`
- Modify: `elixir/lib/symphony_elixir/tracker.ex`

1. Implement issue fetch/list/get/comment/update and label management for Gitea.
2. Normalize Gitea issue JSON into existing `SymphonyElixir.Linear.Issue` struct.
3. Implement terminal mapping:
   - closed + `duplicate` => `Duplicate`
   - closed + `wontfix` => `Cancelled`
   - closed otherwise => `Done`
4. Keep non-terminal open issues as `Todo` unless future explicit state labels are provided.

### Task 2: Extend config schema for Gitea

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/lib/symphony_elixir/config.ex`

1. Add tracker fields for Gitea (`owner`, `repo`, `project_id`).
2. Allow `tracker.kind: gitea` in validation.
3. Validate required Gitea fields and API key.

### Task 3: Add/adjust tests for new tracker behavior

**Files:**
- Create: `elixir/test/symphony_elixir/gitea_adapter_test.exs`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs` (or nearest config tests)

1. Cover issue normalization/state mapping.
2. Cover update-state behavior for `In Progress` and terminal states.
3. Cover config validation for missing Gitea fields.

### Task 4: Rewire Docker quickstart to external Gitea with `.env`

**Files:**
- Modify: `docker-compose.yml`
- Modify: `elixir/WORKFLOW.docker.memory.md` -> replace with `elixir/WORKFLOW.docker.gitea.md`
- Modify: `elixir/docker/entrypoint.sh`
- Modify: `README.md`
- Create: `.env.example`

1. Compose uses env interpolation only; no fallback defaults for required vars.
2. Workflow uses `tracker.kind: gitea` and env-based fields.
3. README documents exact required env variables and stock-label semantics.

### Task 5: Verify and document constraints

**Files:**
- Modify: `README.md`

1. Run `docker compose config`.
2. Run targeted Elixir tests if toolchain exists; otherwise report verification gap.
3. Document explicit limitation: board columns are required operationally, but this Gitea instance does not expose board-column APIs in OpenAPI, so orchestration state persistence currently uses issue state + labels.
