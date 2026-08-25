---
parent: PAID
prefix: PROMPT-DEFAULT-SYNC
---

# Low-Level Design: Prompt Default Synchronization

## Purpose

Paid ships application-owned global prompt defaults as versioned database
records. Existing databases must receive changes to those defaults without
running the repository's broader seed suite, while account- and project-scoped
prompt overrides remain untouched.

## Canonical Definitions

The shipped prompt definitions have one executable source of truth. Both the
general database seed entry point and the dedicated synchronization command use
the same synchronization service, so manual setup, development updates, and
deployments cannot apply different prompt content.

The synchronization scope is limited to global prompts whose `account_id` and
`project_id` are both null. Sample data and unrelated configuration seeds are
outside this component.

## Version Synchronization

For each shipped definition, synchronization finds or creates its global
`Prompt` record and compares the normalized template and variables with the
current version.

- A missing prompt receives its initial immutable version.
- A changed template or variable set receives a new immutable version that is
  promoted to `current_version`.
- An unchanged definition creates no version.
- Account- and project-scoped overrides are never selected or modified.

Synchronization is safe to invoke repeatedly. A transaction-scoped database
advisory lock serializes the comparison-and-create operation across application
processes so concurrent deploy starts cannot create duplicate versions. The
same transaction makes the definition set atomic: a failure rolls back every
prompt and version written by that synchronization pass.

## Update Paths

`bin/rails prompts:sync_defaults` is the common operational interface.

- `db:seed` invokes the same service as part of full environment seeding.
- `bin/dev-update` invokes the command after database migrations or setup and
  before reporting a successful update, including lightweight updates.
- The container server entry point invokes `db:prepare` and the synchronization
  task in one Rails process before starting the server.

Each caller treats synchronization failure as an update or startup failure.
Successful synchronization emits structured counts for prompts created,
versions created, and definitions already current.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Production propagation | Dedicated synchronization command in the deployment path | Run all seeds; one data migration per prompt edit | Full seeds include unrelated development data, while repeated data migrations duplicate synchronization logic and do not provide a reusable repair command. |
| Development propagation | Run the idempotent command after every successful update | Detect only prompt-definition file changes; require manual seeding | Unconditional invocation repairs interrupted earlier updates and avoids coupling correctness to a fragile changed-file list. |
| Concurrent invocation | Transaction-scoped database advisory lock and atomic definition pass | Session advisory lock; optimistic comparison only; unique database constraint | The version table has no content-level uniqueness constraint, application instances may start concurrently, and a failed definition must not expose a partial rollout. |
| Override boundary | Synchronize only unscoped global defaults | Rewrite all matching slugs; never update existing rows | Tenant overrides are user-owned, while never updating the global row recreates the stale-default failure. |
| Failure behavior | Fail the update/startup | Warn and continue | Continuing would report a successful deployment while knowingly serving stale application-owned behavior. |

## Edge-Case Contract

- If no current version exists, synchronization creates one.
- If whitespace-only template differences normalize to the same content, no
  version is created.
- If migrations have not created the prompt tables, callers run database
  preparation first rather than suppressing the error.
- If two processes synchronize simultaneously, the second observes the version
  created by the first after acquiring the lock.
- If a global prompt was edited through an administrative surface, the shipped
  definition becomes the new current version while the immutable prior version
  remains available in history.

## References

- `db/seeds/prompts.rb`
- `bin/dev-update`
- `bin/docker-entrypoint`
- `app/models/prompt.rb`
