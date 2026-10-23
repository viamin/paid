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

## Capability contracts

| Capability | Signal source | Activation policy | Response scope | Limits | Escalation | Handoff |
| --- | --- | --- | --- | --- | --- | --- |
| `elevated_error_monitoring` — Elevated-error monitoring (`ExceptionIncident`) | Ingested application error / health-check telemetry from a project container | Requires the project's Operations phase enabled; no automatic remediation | Record and notify an incident; classify severity | Notification volume bounded by incident severity and per-project incident rate | Untriaged incidents beyond the age threshold escalate to an Inbox request; no autonomous fix | An incident may open a remediation issue; that handoff does **not** authorize issue preparation or coding of the new issue |
| `incoming_error_reports` — Incoming error reports | Operator- or agent-filed issue reports | Requires the Operations phase enabled; each response is an explicit manual action | Record the report, link it to project runtime evidence | One open incident per (project, fingerprint) | Unmatched reports escalate to a classification-gap Inbox request | Remediation work returns to the responsible delivery phase by explicit authorization |
| `incident_triage` — Incident triage (`Automation::Notifications` / Inbox `action_required`) | Blocking notifications and incident records | Always on; project Operations phase governs project-scoped visibility only | Route to the operator Inbox with severity, evidence, and recovery action | Per-user notification budget; `Notifications::Rules` severity gates | Notification backlog escalates per `docs/intent/notification-severity/` | Triage outcome either hands off to a delivery phase through explicit authorization or closes the incident |
| `release_deployment_validation` — Release & deployment validation | Release/deployment completion signals | Requires the Release & Deployment phase enabled **and** the matching subordinate control (release or deployment) | Validate the published artifact or deployment | Per-project release granularity and deployment budget | Failed validation escalates to a blocking notification in Operations | Regression after delivery hands back to Coding, requiring its own authorization |

## Explicit non-goals

- No autonomous operational remediation: Operations creates and routes requests,
  it does not start coding work on its own.
- No separate maintenance or verification phase. Maintenance and verification
  are activities inside the phase whose responsibility they serve.
- No new deployment execution engine; Release & Deployment only classifies the
  capabilities that already exist.
- No inheritance of a continuation grant across an operations handoff. The
  originating issue needs its own authorization.
