---
parent: PAID
prefix: OUTCOME-FEEDBACK
---

# EARS: Outcome Feedback

Draft requirements for [RDR-082](../../rdrs/RDR-082-optional-outcome-feedback-for-autonomous-assessments.md)
and the [owning design](outcome-feedback-design.md). Every claim is unimplemented;
code/test links must be supplied during delivery, with failing-first tests.

- [ ] **OUTCOME-FEEDBACK-001** — When an authorized user votes on a feature
  or criterion, Paid SHALL durably save the vote without requiring explanatory
  text, show confirmation, and permit change or undo.
- [ ] **OUTCOME-FEEDBACK-002** — When recording feedback, Paid SHALL preserve
  author, target scope, timestamp, and known implementation/acceptance
  revisions, distinguish unknown context, and retain change/withdrawal history.
- [ ] **OUTCOME-FEEDBACK-003** — Paid SHALL offer a browsable list of
  user-visible acceptance criteria with quick feedback controls, and SHALL
  NOT extend feature approval to every criterion or carry approval to a later
  implementation automatically.
- [ ] **OUTCOME-FEEDBACK-004** — When reporting a problem, a user SHALL be
  able to omit expected/observed details and feature association; Paid SHALL
  retain the report and distinguish subsequently suggested links from its
  original context.
- [ ] **OUTCOME-FEEDBACK-005** — Paid SHALL distinguish unexamined default
  good, positive human feedback, negative human feedback, and attributed
  assessment failures; unexamined defaults SHALL NOT count as human approval
  or independently measured assessment accuracy.
- [ ] **OUTCOME-FEEDBACK-006** — When feedback is investigated, Paid SHALL
  preserve the original vote and assessment, record supporting links and an
  explicit attribution outcome, and retain inconclusive or disputed reports
  without silently converting them to positive feedback.
- [ ] **OUTCOME-FEEDBACK-007** — When a negative submission is repeated or
  updated, Paid SHALL deduplicate investigation work, retain added context,
  and save feedback even when authority, budget, service availability, or the
  rollout guard prevents investigation from starting.
- [ ] **OUTCOME-FEEDBACK-008** — Feedback SHALL NOT grant execution, merge,
  release, or requirement-change authority; investigations and corrective
  work SHALL obey current project/phase authorization, trust, budget, and
  ordinary admission rules.
- [ ] **OUTCOME-FEEDBACK-009** — Paid SHALL authorize feedback reads/writes
  and investigation context within the current tenant and project, expose
  equivalent UI and agent/API actions, and safely handle untrusted text.
- [ ] **OUTCOME-FEEDBACK-010** — When the replacement workflow is activated
  for autonomous operation, Paid SHALL remove mandatory historical-labeling
  tasks and dependencies reconciled by the migration inventory, preserve
  historical evaluations, and retain explicit approval-gated feature guards.
- [ ] **OUTCOME-FEEDBACK-011** — While outcome feedback is disabled, Paid
  SHALL prevent new collection and investigation starts, preserve saved
  records, and SHALL NOT reinstate historical labeling as a prerequisite for
  autonomous operation or cancel unrelated active work.
- [ ] **OUTCOME-FEEDBACK-012** — When feedback informs assessment evaluation,
  Paid SHALL retain source evidence and scoring version, exclude default-good
  priors from human-observation counts, prevent one report from becoming
  independent duplicate penalties, and SHALL NOT promote prompts/models or
  change live thresholds directly from raw votes.
