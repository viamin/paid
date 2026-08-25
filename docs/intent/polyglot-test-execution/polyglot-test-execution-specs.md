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

- [x] **POLYGLOT-TEST-002** — When a project is imported or re-detected, the
  system SHALL persist a unified language/framework profile that downstream
  consumers can read instead of independently re-detecting from different code
  paths.

- [ ] **POLYGLOT-TEST-003** — When quality hooks or prompt builders need test
  and lint commands, the system SHALL derive them from the persisted language
  profile for the configured test languages rather than defaulting every
  project to Ruby commands. The command map SHALL cover the full RDR-046 target
  matrix (Ruby, JavaScript, TypeScript, Python, Go, Rust, Elixir, Swift);
  polyglot repos SHALL resolve one command per test language, with prompts
  listing each command and the pre-commit hook running each in its own
  availability-checked block.
  *Code:* `app/services/prompts/language_commands.rb`,
  `app/services/containers/quality_hooks.rb`,
  `app/services/containers/git_operations.rb`,
  `app/services/prompts/build_for_issue.rb`, `app/services/prompts/build_for_pr.rb`.
  *Test:* `spec/services/prompts/language_commands_spec.rb`,
  `spec/services/containers/quality_hooks_spec.rb`,
  `spec/services/containers/git_operations_spec.rb`,
  `spec/services/prompts/build_for_issue_spec.rb`.
  *Gap (2026-08-23 closeout):* the command map and multi-command routing logic
  are fully implemented and pass their specs, but every spec sets
  `project.language_profile` directly. Production detection
  (`Projects::DetectRepoProfile`) only ever persists `project.repo_profile`,
  and `Prompts::LanguageCommands.profile_languages` reads
  `project.language_profile` instead — a column no production code path
  writes. Polyglot routing never activates for a real project; it silently
  falls back to the single detected primary language. See
  `docs/rdrs/audit-report-2026-08-23-rdr-046.md` and
  [#3612](https://github.com/viamin/paid/issues/3612).

- [ ] **POLYGLOT-TEST-004** — When a project requires additional runtimes, the
  container/image selection path SHALL resolve a language-appropriate agent
  image instead of using one monolithic hardcoded image for every repo.
  Projects whose detected languages are a subset of the base image runtimes
  (Ruby, Node, Python) SHALL resolve to the base image; projects requiring
  additional runtimes (Go, Rust, Elixir, Swift) SHALL resolve to a combo image
  tag derived from their language set. Chat and knowledge containers SHALL use
  the base image because they run analysis tooling, not the project's own
  runtime.
  *Code:* `app/services/containers/image_resolver.rb`,
  `app/services/containers/provision.rb`,
  `app/services/containers/pool_manager.rb`,
  `app/services/containers/provision_for_chat.rb`,
  `app/services/knowledge/containerized_runner.rb`,
  `app/services/knowledge/embedding_runner.rb`,
  `app/services/knowledge/analysis_runner.rb`.
  *Test:* `spec/services/containers/image_resolver_spec.rb`.
  *Gap (2026-08-23 closeout):* the resolver's tag-computation logic is correct
  and all 5 hardcoded `paid-agent:latest` call sites resolve through it, but
  (a) `ImageResolver#profile_languages` has the same `language_profile` vs.
  `repo_profile` disconnect as POLYGLOT-TEST-003, so it never resolves a combo
  tag for a real project (see [#3612](https://github.com/viamin/paid/issues/3612)),
  and (b) no Dockerfile or build pipeline in the repository produces the combo
  images the resolver names — `docker/agent/languages/` does not exist (see
  [#3613](https://github.com/viamin/paid/issues/3613)).

- [x] **POLYGLOT-TEST-006** — When the image resolver cannot map a detected
  runtime to any supported agent image, it SHALL surface the unsupported
  runtime(s) rather than silently substituting the base image. In strict mode
  the resolver SHALL raise so callers that must run in the correct image fail
  loudly; in the default fallback mode it SHALL resolve to the base image and
  expose the unsupported languages for observability.
  *Code:* `app/services/containers/image_resolver.rb`.
  *Test:* `spec/services/containers/image_resolver_spec.rb`.

- [D] **POLYGLOT-TEST-005** — Swift support SHALL remain limited to
  Linux-capable Swift Package Manager projects; iOS-only Xcode targets are out
  of scope for this segment.
