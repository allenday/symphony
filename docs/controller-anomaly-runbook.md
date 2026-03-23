# Controller Anomaly Matrix And Remediation Runbook

## Purpose

Provide a stable, operator-facing blueprint for controller anomaly detection and deterministic
remediation actions across forges.

## Typed Comment Contract

All controller interventions should use this parseable block:

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

Backends map these capabilities to concrete APIs.

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

## Deterministic Action Order

Apply remediations in this order:

1. `issue.comment.write` (typed controller block with anomaly ID)
2. `issue.assignee.write` (next owner)
3. `issue.state.write` (recovery state)

Idempotency: skip duplicate writes when latest controller comment already records the same anomaly
ID and target assignee/state for the current poll window.

## Escalation

- Retry detection each poll.
- Retry mutation writes up to 3 times.
- After 3 write failures, emit `A00_UNKNOWN_CONTROLLER_GUARD` and stop auto-mutation for that issue
  until human acknowledgement.

## Current Coverage

- Implemented: `A03`, `A04`, `A05`, `A06` (procedural handoff guard).
- Planned next: `A01`, `A02`, `A07`, `A08`.
