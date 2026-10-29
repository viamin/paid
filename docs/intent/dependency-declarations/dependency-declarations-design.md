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
recognises them. Negative and removal directives retain their ordered-comment
semantics.

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
from inline parsing.

## Shared Consumers

`Issues::ParseDependencies` is the single extraction contract. It persists
Auto-Pick edges when an issue is synchronized and is also called directly by
`PullRequests::DependenciesResolved` with the current PR body and ordered
comment bodies. This prevents a stale association from bypassing an unresolved
live declaration.

## Blocking graph invariant

Every `IssueDependency` local-edge write validates the proposed account-scoped
blocking graph. The validation derives and reports the exact cycle path, so it
also covers direct writers and a qualified external declaration when a later
sync resolves it to a tracked issue. A child-to-parent reference remains a
contextual relationship and is excluded from that graph. Parser batches update
their shared adjacency after each accepted edge, so a later item in the same
batch is evaluated against earlier additions.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
| --- | --- | --- | --- |
| Bare-reference admission | Markdown list grammar only within dependency sections | Parse all section prose; semantic keyword heuristics | List syntax is deterministic, intentional, and avoids making an implementation inventory a merge gate. |
| Consumer contract | One shared extractor | Separate Auto-Pick and Auto-Merge parsers | Both gates must interpret the same declaration text identically. |

## References

- `app/services/issues/parse_dependencies.rb`
- `app/services/pull_requests/dependencies_resolved.rb`
