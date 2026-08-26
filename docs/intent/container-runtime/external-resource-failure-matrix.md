# External Resource Failure Matrix

This matrix defines the expected recovery behavior for runner-managed external
execution resources. It is the behavioral acceptance target for the runner
conformance work tracked by `#3347`.

| Window | Persisted state before failure | Live provider state | Expected recovery path |
|---|---|---|---|
| Before provider create call | Provisioning intent `pending` | No resource | Retry may re-run provision normally; no cleanup required. |
| After provider create returns, before handle persistence | Provisioning intent `created`, ownership tags on live resource | Resource exists, handle not persisted | Reconciliation discovers the orphan from the intent row or ownership tags, enqueues cleanup, and deletes the resource without requiring a persisted runner handle. |
| After handle persistence, before workload start | Provisioning intent `linked`, `agent_runs.runner_handle` persisted | Resource exists | Retry reconnects through the runner handle and reuses or cleans up the environment idempotently. |
| During workload start/execute | Handle persisted | Resource exists, workload may be running | Retry reconnects via the runner, checks status, and either resumes observation or cancels and cleans up. |
| Temporal cancellation / timeout | Handle persisted or crash-window intent exists | Resource may still exist | Cancellation and cleanup route through the runner abstraction. If direct cleanup fails transiently, the durable cleanup queue retries with backoff. |
| Cleanup succeeds | Cleanup queue row completed; provisioning intent reconciled | Resource deleted | No further action beyond audit/logging. Re-running cleanup is a no-op. |
| Cleanup fails transiently | Cleanup queue row pending with incremented attempts and `next_attempt_at` | Resource still exists | Background reconciliation retries later with backoff; failure is observable in the queue row and logs. |
| Cleanup fails permanently / operator issue | Cleanup queue row remains pending with latest error | Resource still exists | System keeps surfacing the failure for operator action; no silent drop. |
| Runner cannot list by tag | Provisioning intent and/or handle persisted | Resource may exist | Reconciliation degrades explicitly: cleanup can still run from known handles or known orphan intents, but broad tag sweeps are skipped. |
| Docker legacy janitor overlap | Existing Docker labels plus ownership tags | Resource may exist | The legacy Docker orphan janitor remains authoritative for broad Docker sweeps; runner reconciliation still handles crash-window intent cleanup without regressing Docker behavior. |
