# RDR-075 M03 — Unnecessary-code recipe evaluation status — 2026-11-21

- **Issue:** [#4330](https://github.com/viamin/paid/issues/4330)
- **RDR:** [RDR-075](RDR-075-general-maintenance-runs.md)
- **Scope:** the remaining recipe-specific evaluation requested after #5190
  and #5222; this is not an operating maintenance rollout, recurring run, or
  repair authorization.
- **Repository baseline inspected:** `de98d19c64e13c4f6c9ca194144ac95983e9bfb8`
- **Status:** blocked on authorized execution evidence.

## Criterion plan and current evidence

| Criterion | Smallest credible verification | Current result |
| --- | --- | --- |
| Exhale duplication/complexity adapter | Isolated, pinned Ruby fixture with deliberate duplication; record Exhale version, configuration, JSON, exit code, elapsed time, and semantic disposition | Not run in this environment. Adapter contract is covered by `spec/services/maintenance_runs/tool_evidence_spec.rb`. |
| Knip unused files/exports/dependencies adapter | Isolated, pinned JS/TS fixture with a deliberately unused item; record Knip/Yarn versions, configuration, JSON, exit code, elapsed time, and semantic disposition | Not run in this environment. The `--silent` JSON invocation and exit-one handling are covered by `spec/services/maintenance_runs/tool_evidence_spec.rb`. |
| Deliberate duplication counterexample | Versioned fixture whose two similar paths have an explicit independent-policy reason; agent assessment must retain it as counterevidence, not recommend extraction | Not run: requires a real isolated agent-harness assessment. |
| Dynamic callback counterexample | Versioned Rails fixture with a framework/dynamic callback that static analysis cannot prove reachable; agent assessment must report unresolved/dynamic counterevidence, not deletion | Not run: requires a real isolated agent-harness assessment. |
| Externally consumed API counterexample | Versioned fixture with a public API used outside static repository callers; agent assessment must retain compatibility/API counterevidence | Not run: requires a real isolated agent-harness assessment. |
| Prompt-only fallback | Versioned repository with no applicable adapter; record that no tool check is planned, the prompt-only report, elapsed time, harness token/cost metadata, and limitations | Adapter contract is covered by `spec/services/maintenance_runs/tool_evidence_spec.rb`; the actual agent assessment is not run. |

The current native adapter definitions name Exhale (`bundle exec exhale dry` and
`complexity`, JSON) and Knip (`yarn --silent knip --reporter json`), record the
version probe and searched configuration files, accept documented finding exit
code `1`, and run only through the run's execution environment. The prompt
requires the agent to treat this output as untrusted candidate evidence and to
consider deliberate independence, framework callbacks, dynamic invocation, and
externally consumed APIs. Those are implementation-contract checks, not an
accuracy evaluation.

## Attempt record

This run prepared the application database and inspected its routing state.
The local database has zero `Account`, `User`, `Runner`, and runner-credential
records. Consequently `Llm::Request` has no owning, configured runner through
which it can invoke `agent_harness`. The workspace also has no Docker client,
so it cannot provision the required isolated run checkout for the versioned
fixtures. No provider request was attempted, no synthetic semantic result was
created, and no analyzer was executed on the control-plane host.

These are deliberate non-results: a mocked assessment or a host execution
would not establish the requested criteria. No calibrated confidence, accuracy
rate, token count, cost, or latency is claimed.

## Required follow-up evidence

Run the six planned cases in a provisioned isolated execution environment with
an authorized configured runner. For every case, retain the fixture revision,
agent image/check-out identity, analyzer/package/configuration versions, raw
candidate output, agent-harness structured report and disposition, elapsed
time, resource usage, token/cost metadata where returned, and limitations.
Calculate only transparent observed counts (for example, dispositions matching
the fixture's declared expected outcome); do not turn those small fixture
counts or model output into calibrated confidence. Preserve negative and
unavailable cases alongside any true positives.

Until that evidence exists, this report does not close #4330 or change either
the `maintenance_runs` default-off guard or RDR-073's separate tool policy.
