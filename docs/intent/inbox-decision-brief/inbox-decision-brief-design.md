---
parent: PAID
prefix: INBOX-DECISION-BRIEF
---

# Low-Level Design: Inbox Decision Brief

## Purpose

Every human-actionable Inbox item opens with a short, self-contained decision
brief: what needs deciding, Paid's recommended next step when it can ground
one, why, what work is waiting, and what happens after the operator acts.
Examples, detailed reasoning, evidence, and technical history stay behind a
clearly named expandable section (#4864). This lowers the cost of every human
gate: the operator must not have to reconstruct the project's goal or infer
what Paid expects before making the actual decision.

## Contract

`Inbox::DecisionBrief.call(entry:)` derives a `Brief` value object from one
`Inbox::Queue::Entry`. The Brief carries plain-language fields:

| Field | Meaning |
| --- | --- |
| `goal` | The current project goal or agreed intent behind the work item |
| `changed` | What changed to bring this item to a human now |
| `decision` | The exact decision or action needed |
| `impact` | What work is waiting while the item is unresolved |
| `recommendation` / `rationale` | Paid's recommended next step and why, when grounded |
| `question` | One focused question when no recommendation can be grounded |
| `after_action` | What happens after the operator acts |
| `unknowns` | Disclosures for stale, unavailable, or conflicting evidence |
| `evidence` | Plain-language evidence summaries for the expandable section |
| `primary_action` | Optional `{ label:, url:, external: }` navigation action |

Four surfaces consume the same contract:

- **List rows** (`dashboard/_inbox_list.html.erb`) render the list-safe
  subset (`decision`, `impact`, `question`) beneath the work-item title.
- **Selected detail** (`dashboard/_inbox_decision_brief.html.erb`, rendered
  at the top of the detail body before the per-kind pane) renders the full
  brief with the evidence behind a `<details>` disclosure.
- **API detail/list** (`Api::V1::InboxEntrySerializer`) exposes `brief`
  (`render_list` intentionally narrows it to the list-safe subset, matching
  the existing progress/history split).
- **Contextual chat** (`Inbox::ChatContext`) exposes a `decision_brief`
  section so a chat agent answers with the same recommendation basis.

## Derivation rules

- **Structured state only.** Every field is derived from state the entry
  already carries (kind, record, issue, precomputed snapshots such as
  `guidance` and `closeout_status`) or from bounded reads the detail pane
  already performs. No render-time LLM call participates; nothing in this
  segment adds one.
- **List safety.** The list-mode brief (`call(entry:)` without `detail:`)
  performs no remote calls and no additional database queries per row, so
  queue listing stays O(1) per entry. Detail-only enrichment (manual-review
  provenance, acceptance assessment, last agreed decision) happens in
  `detail: true` mode.
- **Recommendations are grounded.** A recommendation appears only when the
  lane's structured state supports one (for example merge-approval guidance,
  a recorded acceptance assessment, a manual-review provenance
  classification). Otherwise the brief discloses what is unknown in
  `unknowns` and asks one focused `question`.
- **Staleness is disclosed, not asserted.** When supporting evidence is
  stale (stale approval revision, stale acceptance assessment), the brief
  says so in `unknowns` rather than presenting the recommendation as
  certainty.
- **Plain language by construction.** Brief copy is authored per lane from
  structured values; internal policy slugs, raw JSON, and hashes do not
  flow through. Technical detail (revisions, counters, declaration
  provenance) belongs in `evidence`, rendered only inside the disclosure.

## After-action flow

Acting on an item keeps the existing redirect contract: the acting
controller returns to the filtered Inbox (project/kind/sort preserved via
`return_to` / hidden inbox fields) and the Inbox selects the next relevant
entry. The next entry's own brief — its project, goal, and last agreed
decision (`last_decision`, derived detail-only from the persisted
`InboxHistoryEvent` timeline or lane state such as the latest recorded
conformance decision) — makes the next item self-contained, so the operator
never needs to remember context from the item they just closed. No new
action endpoints or action semantics are introduced by this segment.

## Boundaries

- Authorization, revision checks, action semantics, accessibility, and
  direct links are owned by the existing lanes (`docs/intent/operator-inbox/`
  and the per-lane segments); this segment only adds the shared brief
  presentation on top and must not fork an action. Brief links obey the
  inbox navigation-intent guard (`docs/intent/inbox-navigation-intent/`).
- Related lanes keep their own fixes: #4678 (one Action Required subtype)
  and #4780 (internal RDR copy) are not duplicated here; this segment owns
  only the common presentation pattern.
- #4864's measurement criterion (time and clicks to next action on
  representative items, including cross-project switches) is an operator
  usability study, not an automated check; it is recorded as external
  evidence to be gathered, not asserted by tests.

## Decisions & Alternatives

| Decision | Alternatives | Rationale |
| --- | --- | --- |
| One service with one branch per Inbox kind (mirroring `InboxEntrySerializer`) | Per-kind brief classes; storing briefs on `Entry` members | The kind dispatch is one `case`; per-kind classes would scatter the contract the serializer precedent deliberately keeps together. Storing briefs on the struct would compute them for every row at queue-build cost. |
| List-safe mode separate from `detail: true` | Always full brief | Queue listing must stay free of per-row queries and remote calls (same principle as `progress_payload` being detail-only in the serializer). |
| `last_decision` from `InboxHistoryEvent` + lane state | Always query full `Inbox::ActionHistory` | One indexed newest-first lookup bounded to the detail pane is enough for a single line; the full timeline already renders below. |
| Brief primary action only when the lane's action is a navigation | Duplicating lane form actions in the brief | Duplicating an embedded form (approve/reject, evidence-gated close) would fork action semantics the lanes own; the per-kind panes remain the action surface and already render one visually prominent primary control. |

## Open Questions & Future Decisions

- Copy tuning per lane (word counts, ordering) should be informed by the
  #4864 operator measurement once that external evidence exists.
