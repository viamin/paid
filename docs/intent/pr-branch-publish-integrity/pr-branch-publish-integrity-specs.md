# EARS: PR Branch Publish Integrity

## Expected remote head identity

- [x] **PR-BRANCH-PUBLISH-001**: When `GitOperations#clone_and_checkout_branch` checks out an existing PR's remote branch and persists admission state, the system shall record the checked-out HEAD SHA as `AgentRun#expected_remote_head_sha` if no value is already recorded for that run.
- [x] **PR-BRANCH-PUBLISH-002**: The system shall never overwrite an already-recorded `AgentRun#expected_remote_head_sha` on a subsequent checkout of the same run.

## Lease expectation source

- [x] **PR-BRANCH-PUBLISH-003**: When publishing an existing PR branch or force-publishing after a conflict rebase, the system shall use `AgentRun#result_commit_sha` (when present) or else `AgentRun#expected_remote_head_sha` as the `--force-with-lease` expected SHA, and shall not substitute a SHA read from a `git fetch` issued by that same push attempt.
- [ ] **PR-BRANCH-PUBLISH-004**: If neither `result_commit_sha` nor `expected_remote_head_sha` is recorded for the run, the system SHALL hold publication without fetching a substitute lease or pushing, retain the exact local result revision, and explain that recovery requires reconciling that result in a fresh run with a captured remote head. A legacy run SHALL NOT authorize overwriting contributor work. Source issue: #5177; acceptance pending.

## Rejected-lease recovery (existing-PR publish route)

- [x] **PR-BRANCH-PUBLISH-005**: When the first `--force-with-lease` push for an existing PR branch is rejected as stale, the system shall fetch the full repository history, fetch the current remote branch tip, and attempt a rebase of the run's local commits onto that tip before retrying the push.
- [x] **PR-BRANCH-PUBLISH-006**: If the rebase in PR-BRANCH-PUBLISH-005 conflicts, then the system shall abort the rebase, raise `PushError` describing that the branch advanced remotely, and shall not push, discard the local commits, or fabricate a successful result.
- [x] **PR-BRANCH-PUBLISH-007**: If the rebase in PR-BRANCH-PUBLISH-005 succeeds, the system shall retry the push once with `--force-with-lease` set to the fetched remote tip from PR-BRANCH-PUBLISH-005.
- [x] **PR-BRANCH-PUBLISH-008**: If the retried push in PR-BRANCH-PUBLISH-007 is also rejected as stale, then the system shall raise `PushError` describing that the remote head changed again and shall not retry a further time (bounded recovery, not an unbounded loop).

## Force-publish route (conflict-rebase republish)

- [x] **PR-BRANCH-PUBLISH-009**: `GitOperations#push_force_with_lease` shall use the same lease-expectation source as PR-BRANCH-PUBLISH-003 and PR-BRANCH-PUBLISH-004, rather than a SHA read from a `git fetch` issued by that same push attempt.
- [x] **PR-BRANCH-PUBLISH-010**: If the push in PR-BRANCH-PUBLISH-009 is rejected as stale, then the system shall raise `PushError` without an added rebase-and-retry attempt, preserving the existing caller-level handling (`Conflicts::Resolve` records a `manual` resolution outcome).

## Isolation

- [x] **PR-BRANCH-PUBLISH-011**: The expected-remote-head identity and lease expectation shall be read from the publishing `AgentRun` only; a push for one agent run's branch shall never read or be affected by another agent run's `expected_remote_head_sha` or `result_commit_sha`.

## Rejected local result retention

- [x] **PR-BRANCH-PUBLISH-012**: Before attempting a publish, the system shall persist the local HEAD as `AgentRun#unpublished_result_commit_sha`; if publication is rejected, that exact revision shall remain available for recovery, while a successful publish shall move the published HEAD to `result_commit_sha` and clear the unpublished value.
