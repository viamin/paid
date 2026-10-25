---
parent: AUTOMATION-PHASES
prefix: AUTOMATION-PHASES
---

# Operations Ownership and Handoff Contracts

RDR-077 §6 requires the initial implementation to inventory existing operational
capabilities and assign ownership **without adding autonomous remediation**.
This document is that inventory. `Automation::Operations::ContractCatalog`
holds the same contract data as structured records, and
`spec/services/automation/operations/contract_catalog_spec.rb` asserts that every
declared capability is complete and that the documented table and the code
cannot drift.

## Ownership rule

Operations describes **project-runtime** work: observing software Paid
delivered and responding to its operational signals. Paid's own infrastructure
health, credential, and safety requests are platform concerns, not project
operations; they are classified with no phase, stay visible regardless of a
project's Operations phase, and never gain execution authority from a project's
settings.

## Shipped capability evidence

`Automation::Operations::ContractCatalog` is the machine-readable inventory.
It deliberately names only the behavior the cited service and test establish.
The Operations flag is default-off, so these existing services retain their
pre-phase behavior while `automation_phases` is off.

| Capability | Signal source | Activation policy | Response scope | Limits | Escalation | Completion meaning | Handoff | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `exception_incident_handling` | Actionable exceptions passed to `ExceptionHandler::Handle`, with optional project context | Always captures platform safety signals; Operations does not gate capture or filing | Fingerprint, persist, rate-limit, classify, and notify an `ExceptionIncident` | Five occurrences/fingerprint/hour; 500 occurrences/account/hour | P1 publishes an error notification; actionable project incidents may proceed to issue filing | The exception is logged, or its occurrence is recorded on an ExceptionIncident after applicable filing and notification are attempted. | An incident handoff grants no issue preparation or coding authority; normal delivery policy is still required | `app/services/exception_handler/handle.rb`; `spec/services/exception_handler/handle_spec.rb` |
| `incident_issue_filing` | Project-scoped allowlisted `ExceptionIncident` without a GitHub issue | `ExceptionHandler::Handle` invokes filing; Operations does not gate it | Create one GitHub issue or append an occurrence comment | One filing claim/incident; stale claim recovery after five minutes | GitHub errors release the claim; concurrent filing retries | A new GitHub issue is recorded on the incident, an occurrence comment is added to its existing issue, or a recoverable filing failure releases its claim. | The remediation issue grants no issue preparation or coding authority; only independently applicable delivery policy can do so | `app/services/exception_handler/issue_filer.rb`; `spec/services/exception_handler/issue_filer_spec.rb` |
| `incident_triage` | Blocking notifications and incident records | Notification publication is independent of Operations; ownership affects only project-scoped Inbox relevance once the rollout is enabled | Route existing blocking notifications to Inbox with severity, evidence, and recovery action | Per-user notification budget and severity gates | Backlog follows `docs/intent/notification-severity/` | The blocking notification is routed to the operator Inbox with its recovery action, or the incident is closed without a delivery handoff. | Triage can close the incident or hand off through explicit delivery authorization | `app/services/inbox/phase_ownership.rb`; `spec/services/inbox/phase_ownership_spec.rb` |
| `auto_release_evaluation` | Release Please pull-request and CI signals | Release & Deployment phase authorization plus the release control; no deployment control consumer exists | Evaluate and potentially merge an eligible release PR; does not publish an artifact or deploy software | One evaluation/project; configured release granularity | Parse, CI, and expected merge failures are recorded as auto-merge attempts | The eligible release PR is merged, or its evaluation records the CI, parse, or expected merge outcome without deploying software. | Merging a release PR does not authorize deployment | `app/temporal/activities/evaluate_auto_release_activity.rb`; `app/jobs/auto_release_evaluation_job.rb`; `spec/jobs/auto_release_evaluation_job_spec.rb` |

## Explicit follow-up scope

The following RDR-077 concepts are not shipped capabilities. They are recorded
here as an execution boundary, not represented as available automation.

| Capability | Current evidence | Completion meaning | Required future contract owner |
| --- | --- | --- | --- |
| `incoming_error_reports` | No distinct inbound report producer, persistence, deduplication, or Inbox escalation exists. Ordinary GitHub issues use the normal issue-sync path (`app/services/exception_handler/issue_filer.rb`; `app/models/issue.rb`). | No operational completion exists until a future producer defines and verifies a dedicated intake and response outcome. | A separately authorized Operations delivery task must define the producer, account isolation, operator authorization, response and escalation path, and the no-authority handoff. |
| `deployment_execution` | `Automation::PhaseSettings` stores a deployment control, but no executor, completion signal, validation, budget, or failure-notification path consumes it (`app/services/automation/phase_settings.rb`; `app/services/automation/feature_activation.rb`). | No operational completion exists until a future executor defines and verifies deployment and validation outcomes. | A separately authorized Release & Deployment delivery task must define execution, validation, budget, rollback, and an independent deployment authorization gate. |

`Automation::Operations::ContractCatalog` retains both entries as
`follow_up`, with their concrete evidence references, so settings do not imply
that either behavior exists.

## Maintenance and verification responsibility

Maintenance and verification remain activities, not phases. Existing release
PR CI evaluation belongs to Release & Deployment; exception observation and
notification triage belong to Operations; repository maintenance and
correspondence verification have no shipped Operations execution path.

RDR-075's general maintenance runs remain blocked on its explicit tool-handoff
validation and are not available behavior. RDR-076's layered verification is
accepted design whose implementation status remains unshipped. Neither design
authorizes an Operations response, remediation, release, or deployment in this
catalog.

## Pilot and final-audit evidence

Before an `automation_phases` pilot enables Operations, the accountable pilot
operator must verify: the four shipped rows above against their cited tests;
the platform/Operations distinction through `Inbox::PhaseOwnership`; a created
incident issue has no continuation grant or incident-derived delivery
authority; release works only through the release control; and deployment is
still absent. The final audit records those results per project, with the
feature-flag state and any remaining follow-up owner, before claiming the
Operations contract complete.

## Explicit non-goals

- No autonomous operational remediation: Operations creates and routes requests,
  it does not start coding work on its own.
- No separate maintenance or verification phase. Maintenance and verification
  are activities inside the phase whose responsibility they serve.
- No new deployment execution engine; deployment remains explicit follow-up
  scope rather than a claimed capability.
- No inheritance of a continuation grant across an operations handoff. The
  originating issue needs its own authorization.
