# Dependency cycle recovery specifications

- [x] **DEPENDENCY-CYCLES-001** — When an account's persisted effective blocking dependency graph contains a strongly connected group, the system SHALL persist one active occurrence for that group with a stable member-set identity.
- [x] **DEPENDENCY-CYCLES-002** — When reconciling an occurrence, the system SHALL retain a concrete cycle path, declaration provenance where available, project/issue links, and the count of downstream held issues, and SHALL not mutate a dependency declaration.
- [x] **DEPENDENCY-CYCLES-003** — When an active cycle occurrence is visible to an operator, the Inbox and dashboard SHALL show a recovery route that explains the cycle cannot resolve as independent prerequisites; the dashboard SHALL remain visible outside capped held-issue details.
- [x] **DEPENDENCY-CYCLES-004** — When a subsequent reconciliation observes an acyclic effective graph, the system SHALL resolve only the matching occurrence; unavailable reconciliation coverage SHALL not be represented as zero cycles.
