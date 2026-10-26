---
parent: PAID
prefix: QUEUE-DIAGNOSIS
---

# Low-Level Design: Queue Diagnosis

## Purpose

An empty Upcoming Queue is an observation about queued `AgentRun` rows, not a
claim that a project has no work. This segment makes the distinction visible
without changing admission policy: it projects the canonical candidate scope,
queued runs, active runs, explicit pauses, and inspectable blocking evidence
for the signed-in operator's visible projects.

## Diagnosis

`Dashboard::QueueDiagnosis` is a read-only projection. It reuses
`Dashboard::EligibilityBreakdown` for eligible-candidate counts and the
scheduler's queued/active `AgentRun` scopes. Its states are:

| State | Meaning | Supported action |
| --- | --- | --- |
| `queued` | Queued work exists. | Inspect the upcoming queue. |
| `healthy_active_work` | Nothing waits while work is active. | Monitor active work. |
| `runnable_unseeded` | Canonically eligible work exists without queued work. | Wait for the bounded eligibility sweep; it will seed normal admission. |
| `dependency_or_decision_hold` | No candidate is waiting and local dependency or Inbox-held work remains. | Inspect the named blockers or Inbox. |
| `resource_or_policy_pause` | An explicit project/account scheduler or quality pause prevents admission. | Resume only when authorized. |
| `no_waiting_work` | No queued, active, eligible, or held work is visible. | No recovery action. |
| `unknown` | Required data could not be read. | Refresh; absence is never interpreted as no work. |

Blocker rows name the dependent issue, all local blocking issues, and the
owner state. The projection deliberately does not perform GitHub calls,
repository execution, agent-harness assessment, or mutations while rendering.
Semantic recovery continues through the established partial-closeout and
Inbox paths; the periodic auto-pick eligibility sweep is the bounded mechanical
recovery path for unseeded eligible work.

## Constraints

- Visibility is account- and owner-scoped exactly as the existing dashboard
  services are; no cross-tenant or non-owner issue data is projected.
- A diagnosis never clears labels, pauses, holds, or approval policy.
- Cache keys use the dashboard list version, so queue-changing events invalidate
  the diagnosis along with the preview; the rendered timestamp identifies its
  freshness.
