# Dependency Declaration EARS

> Parent: [Dependency Declarations](dependency-declarations-design.md)
>
> The IDs below are stable grep targets for implementation and tests.

- [x] **DEPENDENCY-DECLARATIONS-001** — When a dependency section contains a bare local or qualified issue reference in a Markdown bullet, ordered, or checklist list item, the system SHALL extract it as a dependency.
- [x] **DEPENDENCY-DECLARATIONS-002** — When ordinary prose beneath a dependency heading mentions issue references without an explicit directive or list-item declaration, the system SHALL not extract those references as dependencies.
- [x] **DEPENDENCY-DECLARATIONS-003** — When explicit positive, negative, removal, or deployment directives occur in supported locations, the system SHALL retain their existing qualified-reference, deployment-flag, and ordered-comment behavior.
- [x] **DEPENDENCY-DECLARATIONS-004** — When a child section or child-issue list is outside the dependency section, the system SHALL exclude its inline dependency phrases; a later Markdown heading SHALL end bare-reference admission for the preceding dependency section.
- [x] **DEPENDENCY-DECLARATIONS-005** — When Auto-Pick persists an edge or Auto-Merge evaluates a live pull request body and comments, both consumers SHALL use the same extraction contract and Auto-Merge SHALL remain unresolved when declared remote evidence cannot be verified.
- [x] **DEPENDENCY-DECLARATIONS-006** — When a dependency-section list item spans indented continuation lines, the system SHALL extract bare references from the folded item text including those continuation lines.
- [x] **DEPENDENCY-DECLARATIONS-007** — When dependency-section content appears inside a fenced code block, the system SHALL not admit it as a list-item declaration, because fenced content is code rather than Markdown list structure.
