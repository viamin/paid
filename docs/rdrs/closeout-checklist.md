# RDR Closeout Checklist

A reusable process for closing out a Recommendation Decision Record (RDR) against
its shipped implementation. Use this whenever an RDR's implementation chain has
finished (or stalled) and the RDR needs its status reconciled with reality.

> **Why this exists.** The 2026-08-04 RDR gap audit
> ([`audit-report-2026-08-04-*.md`](./)) filed a batch of closeout issues
> (#3161–#3174). Those issues all follow the same shape. This checklist captures
> that shape once so future RDR authors and agents link to it instead of
> reinventing the process — and so two failure modes are avoided:
>
> - marking an RDR **Implemented** just because a related issue is closed
> - filing duplicate implementation work when the code already shipped

## When to run a closeout

Run a closeout when an RDR's status no longer matches the codebase: the
implementation chain shipped, stalled, was superseded, or was abandoned. Do
**not** run a closeout for ongoing implementation work — use the normal issue
chain for that.

## The checklist

Every RDR closeout issue must complete all of these steps. Copy this list into
the issue body and check each box.

### 1. Compare shipped code/tests/docs against the RDR acceptance criteria

- [ ] Read the RDR's **Problem Statement**, **Proposed Solution**, and
      **Validation**/acceptance sections as the source of truth.
- [ ] For each acceptance criterion, locate the shipped code that satisfies it
      (services, models, MCP tools, controllers, views) and the tests that
      prove it (specs, request tests, views).
- [ ] Confirm the test evidence actually runs and asserts the behavior — not
      merely that a spec file exists.
- [ ] Record concrete `file_path:line` / spec-path evidence for each criterion
      in the audit report (see step 7).

**Do not** mark a criterion satisfied by "issue #N is closed." A closed issue
is not evidence; the merged code and its tests are. Verify against the codebase.

### 2. Decide the final status

Pick exactly one based on what step 1 found, not on issue-closed state:

| Status | Use when |
|--------|----------|
| **Implemented** | Every acceptance criterion has shipped code and test evidence. No remaining gaps. |
| **Partially Implemented** | Core scope shipped but some acceptance criteria are still missing; child issues filed for each gap (step 3). |
| **Superseded** | Replaced by a later RDR; record which RDR supersedes it. |
| **Abandoned** | Never implemented and no longer planned; record why. |

### 3. File child issues for any remaining gaps

- [ ] For each unmet acceptance criterion from step 1, file a focused child
      issue describing the exact missing behavior and its acceptance criteria.
- [ ] Make each gap its own issue (not one catch-all), so it is independently
      pickable and verifiable.
- [ ] If no gaps remain, state that explicitly and file nothing.

### 4. Update the RDR

- [ ] Update the `## Implementation Status` section so it describes **what
      actually shipped** today, with the new status and date.
- [ ] Update the **Metadata** `Status:` line to the chosen status.
- [ ] Add the closeout issue number and any new child-gap issues to the
      **Metadata** `Related Issues:` line.
- [ ] Add a dated closeout subsection (e.g. `## 2026-08-04 Closeout`) recording
      the shipped behaviors, design deltas, and link to the audit report.
- [ ] Keep the original RDR text as the architectural plan; the closeout records
      where implementation diverged.

### 5. Update `docs/rdrs/README.md`

- [ ] Update the RDR's **Status** column in the index table to match step 2.
- [ ] If the RDR was superseded, point its row at the superseding RDR.

### 6. Label hygiene (do not block auto-pick)

Closeout and child-gap issues that Paid automation should pick up must **not**
carry any label from the repository's **effective** auto-pick skip set. That
set is resolved by `Project#effective_auto_pick_skip_labels` in this order:

1. `project.auto_pick_skip_labels`
2. `project.effective_owner.user_setting.auto_pick_skip_labels`
3. `project.account.tenant_setting.auto_pick_skip_labels`
4. `AutoPickSkipLabels::DEFAULTS`

The built-in fallback defaults in
`app/models/concerns/auto_pick_skip_labels.rb` are:

```
planning, research, waiting, tracking, epic, needs-manual-setup
```

- [ ] Confirm the closeout issue (and each child-gap issue) carries **none** of
      the effective skip labels configured for that project if it should be
      auto-picked.
- [ ] In particular, never label an automation-pickable closeout issue
      `planning` — that label keeps it out of the queue indefinitely.
- [ ] Reserve `planning` for issues that need human/LLM planning before any
      implementation, not for reconciliation audits that resolve to doc edits
      and filed follow-ups.

### 7. Store the audit as an RDR-specific artifact

- [ ] Write the audit findings to `docs/rdrs/audit-report-<date>-rdr-<NNN>.md`.
      Always include the RDR number so multiple closeouts on the same date do
      not collide on one generic filename.
- [ ] The audit report records: the RDR, the audit date, the closeout issue
      number, what shipped (with evidence), what is still missing, and the
      conclusion (the status from step 2).

### 8. Close or keep the umbrella issue intentionally

- [ ] If the closeout status is **Implemented** and no gap issues remain, make
      the closeout PR visibly close the umbrella/closeout issue with GitHub
      closing language such as `Closes #1234`.
- [ ] If the closeout status is **Partially Implemented**, **Superseded**, or
      **Abandoned** and the umbrella should remain open for follow-up work, use
      non-closing language such as `Tracks #1234` and explain in the RDR why no
      closure is claimed.
- [ ] Do not rely on Paid's local `paid_state` as the source of truth for
      closure; GitHub-visible closing references and issue state must tell the
      same story a user sees.

## Linking existing closeout issues

Closeout issues filed before this checklist existed do not need to be rewritten.
New and existing closeout issues should simply reference this checklist:

> Follows the [RDR Closeout Checklist](https://github.com/viamin/paid/blob/main/docs/rdrs/closeout-checklist.md).

so the process lives in one place rather than being reinvented per issue.

## Anti-patterns to avoid

- **"Issue closed → RDR implemented."** A closed GitHub issue only means its PR
  merged. Verify the merged code against the RDR's acceptance criteria.
- **"No issue → not implemented."** Features sometimes ship without a tracking
  issue. Search the codebase; do not assume unimplemented just because an issue
  is open or missing.
- **Re-filing shipped work.** Before creating a child gap issue, confirm the
  behavior is genuinely absent in the code — it may have shipped under a
  different name or in an earlier phase.
- **Catch-all gap issues.** One issue per unmet criterion, so each is
  independently pickable and verifiable.
- **Skip labels on pickable work.** A `planning` (or other skip) label on a
  closeout/child issue silently removes it from auto-pick forever.
