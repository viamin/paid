---
parent: PAID
prefix: DEPENDENCY-DECLARATIONS
---

# Dependency Declarations

## Context and Design Philosophy

Dependency declarations are a structural contract shared by Auto-Pick's
persisted dependency edges and Auto-Merge's live pull-request gate. Parsing
must fail closed when a declared remote dependency cannot be verified, without
turning unrelated issue references into prerequisites.

## Declaration Grammar

Explicit `Depends on`, `Blocked by`, and deployment directives continue to
admit local and qualified `owner/repo#N` references wherever the parser already
recognises them. Those directives do not apply when they appear as Markdown code
examples or describe another numbered issue's dependency status or
prerequisites, including in a dependency-section list item. A sentence about
another issue's ordering cannot impose that ordering on the issue carrying the
sentence. This includes a numbered subject immediately followed by a comma and
a supported directive, with or without an auxiliary: `#4707, blocked by
owner/repo#557` and `#4707, is blocked by owner/repo#557`. The comma must be
immediately attributable to the numbered subject; an unrelated reference
elsewhere earlier in the sentence does not suppress a current-item directive.
Negative and removal directives retain their ordered-comment
semantics. When one list item contains
both a bare declaration for the current item and another issue's ordering, the
bare declaration remains in effect.

Under a Markdown heading containing `Dependency` or `Dependencies`, a bare
reference is a declaration only when it is in a Markdown list item: unordered
`-`, `*`, or `+`, or ordered `N.` / `N)`, with an optional `[ ]` or `[x]`
checklist marker. At section scope, an item marker indented by four or more
spaces is an indented code block, not a declaration. A list item's continuation
lines fold into the same item only when they reach its content position,
measured in CommonMark columns with tabs advancing to four-column stops. Thus,
a wrapped `- #41,` item followed by a two-space-indented `#42` declares both
references while a one-space line does not, but `-\t#41` followed by a
two-space-indented `#42` does not. Ordinary
section prose, including implementation inventories, is not a dependency
declaration, and neither is fenced-code content: a fenced block preserved in a
section body is code, not Markdown list structure, so list-style lines inside it
are not declarations. A fenced block closes only on the same delimiter
character with a run at least as long as its opening delimiter. A subsequent
heading ends the dependency section; child/sub-issue sections remain excluded
from inline parsing. The same folding rule applies while identifying a numbered
issue as the subject of a directive: a wrapped directive about another issue
does not become a declaration for the current item.

## Shared Consumers

`Issues::ParseDependencies` is the single extraction contract. It persists
Auto-Pick edges when an issue is synchronized and is also called directly by
`PullRequests::DependenciesResolved` with the current PR body and ordered
comment bodies. This prevents a stale association from bypassing an unresolved
live declaration.

For Auto-Merge, a qualified reference outside the current repository remains a
blocking declaration unless its exact normalized owner, repository, and number
match a project tracked by the same account. The gate verifies that tracked
project through its configured provider identity at evaluation time: a closed
issue is resolved, and a pull request is resolved only when merged. Local Paid
state, completed runs, or a sibling relationship never substitute for that
provider result. Missing tracking, inaccessible sources, open issues,
closed-unmerged pull requests, and provider errors remain blocked.

Automatic issue admission uses the same typed prerequisite boundary over the
account-scoped mirror. An open ordinary issue may retain the established
completed or recommend-close exception, but that local workflow state never
resolves a pull request. A pull-request prerequisite resolves only when its
recorded provider lifecycle is closed and merged; open, draft, ready,
closed-unmerged, and incomplete merge evidence remain blocking. Deployment
requirements remain an additional condition after a PR is merged. The shared
contract is consumed by readiness, queue admission and dequeue rechecks,
lifecycle reporting, partial-closeout prerequisite state, and root ranking so
that presentation cannot contradict admission.

## Blocking graph invariant

Every `IssueDependency` local-edge write validates the proposed account-scoped
blocking graph. The validation derives and reports the exact cycle path, so it
also covers direct writers and a qualified external declaration when a later
sync resolves it to a tracked issue. A child-to-parent reference remains a
contextual relationship and is excluded from that graph. Parser batches update
their shared adjacency after each accepted edge, so a later item in the same
batch is evaluated against earlier additions.

Take the account transaction lock before checking a target's outgoing edges.
A distinct target with no persisted dependency rows cannot lead back to the
dependent, so that case needs no account-wide graph load. Self references and
targets with any outgoing declaration retain the full cycle check, including
resolved external edges. The lock remains held through the write so opposing
concurrent declarations cannot both use an empty-target result.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Bare-reference admission | Markdown list grammar only within dependency sections | Parse all section prose; semantic keyword heuristics | List syntax is deterministic, intentional, and avoids making an implementation inventory a merge gate. |
| Consumer contract | One shared extractor | Separate Auto-Pick and Auto-Merge parsers | Both gates must interpret the same declaration text identically. |
| Comma subject attribution | Recognize only an immediately preceding numbered subject followed by a comma and a supported directive | Suppress directives after any earlier issue reference | The bounded punctuation shape captures appositive related-work status without hiding an actual declaration merely because the prose mentions another issue. |
| Cross-project Auto-Merge verification | Resolve only an exact same-account tracked project through its provider identity | Treat a local completed state, arbitrary remote access, or a sibling project as proof | Account-scoped tracking establishes the trusted source; the provider supplies the current lifecycle state and failures fail closed. |
| PR prerequisite fulfillment | Require recorded closed-and-merged evidence for a PR | Treat local Paid completion, recommendation, producer completion, or closed-unmerged state as resolution | A PR is a review artifact whose merge is a separate provider fact; issue workflow states cannot prove it. |

## References

- `app/services/issues/parse_dependencies.rb`
- `app/services/pull_requests/dependencies_resolved.rb`
