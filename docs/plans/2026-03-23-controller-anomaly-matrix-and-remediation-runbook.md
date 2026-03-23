# Controller Anomaly Matrix And Remediation Runbook

## Goal

Define a forge-agnostic anomaly catalog and deterministic controller remediations that can be
executed as procedural checks with optional LLM assist.

## Typed Controller Comment Contract

Controller interventions must use this parseable block:

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

## Capability Model (Forge-Agnostic)

- `issue.read`
- `issue.comment.write`
- `issue.assignee.write`
- `issue.state.write`
- `project.state.read`
- `project.state.write`
- `pr.read`
- `pr.requested_reviewer.read`
- `ci.read`

Backends map these capabilities to concrete endpoints (Gitea, GitHub, Linear+GitHub hybrid, etc).

## Anomaly Matrix

| ID | Pattern | Detection (normalized) | Required capabilities | Remediation | Owner |
| --- | --- | --- | --- | --- | --- |
| `A01_TRIAGE_MISSING_BUDGET` | Issue promoted without triage budget block | `state in {To Do, In Progress} && triage_block missing` | `issue.read`, `issue.comment.write`, `issue.state.write`, `issue.assignee.write` | comment typed controller block, assign `planner`, move `Backlog` | controller |
| `A02_TRIAGE_NOT_READY_PROMOTED` | `ready=false` issue moved out of Backlog | `triage.ready == false && state != Backlog` | `issue.read`, `issue.state.write`, `issue.assignee.write` | assign `planner`, move `Backlog` | controller |
| `A03_REVIEW_HANDOFF_MISSING_LINKED_PR` | Reviewer handoff has no linked PR evidence | `state == Done && linked_pr absent` | `issue.read`, `issue.comment.write`, `issue.state.write`, `issue.assignee.write` | comment, assign `builder`, move `To Do` | procedural |
| `A04_REVIEW_HANDOFF_MISSING_REVIEWER_REQUEST` | PR has no reviewer requested | `state == Done && pr exists && review_request_present == false` | `issue.read`, `pr.read`, `issue.comment.write`, `issue.state.write`, `issue.assignee.write` | comment, assign `builder`, move `To Do` | procedural |
| `A05_REVIEW_HANDOFF_MISSING_PR_CI_STATUS` | Required CI context absent | `state == Done && pr exists && required_ci context absent` | `issue.read`, `pr.read`, `ci.read`, `issue.comment.write`, `issue.state.write`, `issue.assignee.write` | comment, assign `builder`, move `To Do` | procedural |
| `A06_REVIEW_HANDOFF_PR_CI_NOT_GREEN` | Required CI not successful | `state == Done && pr exists && required_ci != success` | `issue.read`, `pr.read`, `ci.read`, `issue.comment.write`, `issue.state.write`, `issue.assignee.write` | comment, assign `builder`, move `To Do` | procedural |
| `A07_ACTIVE_RUN_STALLED` | Running worker exceeds stall timeout | `running && now - last_activity > stall_timeout` | `issue.read`, `issue.comment.write`, `issue.state.write`, `issue.assignee.write` | terminate run, retry once, then comment + requeue `To Do` | orchestrator/controller |
| `A08_REVIEW_ACCEPTED_BUT_NOT_CLOSABLE` | Reviewer accepted but dependency blocks close | `review accepted && close returns dependency failure` | `issue.read`, `issue.comment.write` | comment with blocking dependency IDs, keep `Done` | reviewer/controller |

## Query Templates

Use these normalized query outputs as controller input:

- `issue_snapshot`: `{id, identifier, state, assignee, labels, comments}`
- `triage_snapshot`: `{estimate_tokens, soft_cap_tokens, hard_cap_tokens, ready}`
- `pr_snapshot`: `{number, state, requested_reviewers, head_sha, mergeable}`
- `ci_snapshot`: `{context -> status}`

## Triggered Actions (Deterministic)

Action ordering is fixed for controller remediations:

1. `issue.comment.write` (typed controller block with anomaly ID)
2. `issue.assignee.write` (next owner)
3. `issue.state.write` (target recovery state)

Idempotency rule: if current issue already has same assignee+state and latest controller comment has
same anomaly ID within the last poll window, skip duplicate writes.

## Escalation Policy

- Retry procedural detection every poll.
- Remediation retries: up to 3 attempts for write failures.
- After 3 failures, emit `A00_UNKNOWN_CONTROLLER_GUARD` typed comment and stop auto-mutation for
  that issue until human ack comment is present.

## Controller Runbook

1. Identify anomaly by deterministic query checks.
2. Emit typed controller comment with anomaly ID.
3. Apply ordered remediation actions.
4. Verify post-conditions:
   - assignee changed as expected
   - state changed as expected
   - issue remains visible in expected active state set
5. If verification fails repeatedly, escalate with `A00_UNKNOWN_CONTROLLER_GUARD`.

## Current Implementation Coverage

- Implemented now: `A03`, `A04`, `A05`, `A06` procedural enforcement in Gitea client handoff guard.
- Next implementation slice: `A01`, `A02`, `A07`, `A08`.
