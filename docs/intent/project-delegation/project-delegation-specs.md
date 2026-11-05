---
parent: PAID
prefix: PROJECT-DELEGATION
---

# EARS Specs: Project Delegation After Settled Intent

Status markers: `[ ]` planned implementation gap.

- [ ] **PROJECT-DELEGATION-001** — When an authorized owner or project admin
  selects a project delegation posture, the system SHALL default every project
  to `conservative`, SHALL show the effective posture and remaining required
  human reviews, and SHALL record the actor, project, revision, enabled action
  classes, and audit event.

- [ ] **PROJECT-DELEGATION-002** — When material product questions are known
  before downstream work, the system SHALL group related questions, show a
  recommendation and consequences, and bind a human's settled answers to the
  immutable design and acceptance revision; it SHALL NOT ask again downstream
  unless new evidence conflicts with, invalidates, or materially expands it.

- [ ] **PROJECT-DELEGATION-003** — When `bounded_delivery` is current, the
  system SHALL delegate only bounded implementation choices, focused follow-up
  ownership, technical-stop recovery, evidence-gated issue closure, and
  bounded cycle analysis/repair, each with the action-specific evidence and
  audit record defined by RDR-080; it SHALL NOT delegate product behavior,
  requirements, scope, acceptance criteria, explicit holds, release,
  deployment, settings changes, or new work lineage.

- [ ] **PROJECT-DELEGATION-004** — Before creating, queueing, dequeueing,
  retrying, following up, repairing, or closing delegated work, the system
  SHALL recheck current intent, acceptance, and evidence revisions; posture
  signature; applicable RDR-077/RDR-078 policy; tenant, trust, budget, and
  repository controls; ambiguity, changed scope, conflicting evidence, new
  material risk, explicit holds, or unavailable assessment SHALL route to a
  focused human decision.

- [ ] **PROJECT-DELEGATION-005** — UI, API, MCP, queue, dequeue, retries, and
  background jobs SHALL use `Automation::EffectivePolicy` and the same
  delegation projection; no surface SHALL infer authority from a label, stale
  approval, queue state, or local UI state.

- [ ] **PROJECT-DELEGATION-006** — When a project setting broadens delegated
  authority, the system SHALL apply the broader posture only to new admissions
  and SHALL NOT silently broaden an in-flight authorization; when a project
  setting narrows delegated authority, including rollback to `conservative`,
  or when a hold, expiry, revocation, or bounded stop occurs, the system SHALL
  prevent the next action while preserving audit/evidence history and exposing
  a recovery decision.

- [ ] **PROJECT-DELEGATION-007** — For each opted-in project, the system SHALL
  record revision-aware human Inbox decisions per completed issue, decision
  time, completion rate, and later-reversed decisions; it SHALL keep broadening
  disabled until the RDR-080 pilot threshold is met and SHALL pause expansion
  on a material reversal, security/tenant/trust breach, or missing evidence.
