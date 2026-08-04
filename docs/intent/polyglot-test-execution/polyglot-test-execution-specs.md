# EARS Specs: Polyglot Test Execution

> Testable claims for unified language detection and multi-language execution.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r POLYGLOT-TEST-001`).

- [x] **POLYGLOT-TEST-001** — When the preview and screenshot stack inspects a
  Phoenix repository, the system SHALL recognize Phoenix/Elixir instead of
  falling back to generic Ruby assumptions.
  *Code:* `app/services/screenshots/detect_framework.rb`,
  `app/services/screenshots/container_capture.rb`.
  *Test:* `spec/models/project_spec.rb`,
  `spec/helpers/application_helper_project_type_badge_spec.rb`,
  `spec/services/knowledge/collectors/routes_collector_spec.rb`.

- [ ] **POLYGLOT-TEST-002** — When a project is imported or re-detected, the
  system SHALL persist a unified language/framework profile that downstream
  consumers can read instead of independently re-detecting from different code
  paths.

- [ ] **POLYGLOT-TEST-003** — When quality hooks or prompt builders need test
  and lint commands, the system SHALL derive them from the persisted language
  profile for the configured test languages rather than defaulting every
  project to Ruby commands.

- [ ] **POLYGLOT-TEST-004** — When a project requires additional runtimes, the
  container/image selection path SHALL resolve a language-appropriate agent
  image instead of using one monolithic hardcoded image for every repo.

- [D] **POLYGLOT-TEST-005** — Swift support SHALL remain limited to
  Linux-capable Swift Package Manager projects; iOS-only Xcode targets are out
  of scope for this segment.
