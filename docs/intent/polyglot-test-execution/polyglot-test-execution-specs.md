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

- [x] **POLYGLOT-TEST-003** — When quality hooks or prompt builders need test
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

- [x] **POLYGLOT-TEST-004** — When a project requires additional runtimes, the
  container/image selection path SHALL resolve a language-appropriate agent
  image instead of using one monolithic hardcoded image for every repo.
  Projects whose detected languages are a subset of the base image runtimes
  (Ruby, Node, Python) SHALL resolve to the base image; projects requiring
  additional runtimes (Go, Rust, Elixir, Swift) SHALL resolve to a combo image
  tag derived from their language set. Chat and knowledge containers SHALL use
  the base image because they run analysis tooling, not the project's own
  runtime. Resolved combo tags SHALL correspond to images this repository can
  actually build (see POLYGLOT-TEST-007).
  *Code:* `app/services/containers/image_resolver.rb`,
  `app/services/containers/provision.rb`,
  `app/services/containers/pool_manager.rb`,
  `app/services/containers/provision_for_chat.rb`,
  `app/services/knowledge/containerized_runner.rb`,
  `app/services/knowledge/embedding_runner.rb`,
  `app/services/knowledge/analysis_runner.rb`.
  *Test:* `spec/services/containers/image_resolver_spec.rb`.
  The former `language_profile`-vs-`repo_profile` wiring gap was closed by
  [#3612](https://github.com/viamin/paid/issues/3612); the missing combo-image
  build pipeline was closed by
  [#3613](https://github.com/viamin/paid/issues/3613)
  (POLYGLOT-TEST-007 through POLYGLOT-TEST-010).

- [x] **POLYGLOT-TEST-006** — When the image resolver cannot map a detected
  runtime to any supported agent image, it SHALL surface the unsupported
  runtime(s) rather than silently substituting the base image. In strict mode
  the resolver SHALL raise so callers that must run in the correct image fail
  loudly; in the default fallback mode it SHALL resolve to the base image and
  expose the unsupported languages for observability. The provisioning path
  SHALL resolve strictly so a project with no buildable image fails its run
  instead of provisioning the base image; the warm pool SHALL warm nothing for
  such a project (and drain leftover entries) so a pooled claim cannot bypass
  that strict resolution.
  *Code:* `app/services/containers/image_resolver.rb`,
  `app/services/containers/provision.rb`,
  `app/services/containers/pool_manager.rb`.
  *Test:* `spec/services/containers/image_resolver_spec.rb`,
  `spec/services/containers/provision_spec.rb`,
  `spec/services/containers/pool_manager_spec.rb`.

- [x] **POLYGLOT-TEST-007** — When a container is provisioned with a resolved
  combo image tag that is absent on the target Docker host, the system SHALL
  build that image before creating the container, composing the language
  layers under `docker/agent/languages/` on top of the base agent image
  (`FROM` the base via the `BASE_IMAGE` build arg). An already-present,
  up-to-date tag SHALL be reused without rebuilding; builds SHALL be logged
  with start/success/failure events and duration.
  *Code:* `app/services/containers/combo_image_builder.rb`,
  `app/services/containers/provision.rb`,
  `app/services/containers/backends/base.rb` (`#build_image`).
  *Test:* `spec/services/containers/combo_image_builder_spec.rb`,
  `spec/services/containers/provision_combo_image_spec.rb`.

- [x] **POLYGLOT-TEST-008** — When a combo tag names tokens the language-layer
  matrix cannot build, or a build fails, or the base image the layers compose
  on is missing, provisioning SHALL fail loudly with a specific error and
  SHALL NOT silently fall back to the base image or substitute another tag.
  Non-Paid images (explicit overrides, immutable catalog digest references)
  are outside the builder's ownership and pass through untouched.
  *Code:* `app/services/containers/combo_image_builder.rb`,
  `app/services/containers/image_resolver.rb` (`.combo_tokens`).
  *Test:* `spec/services/containers/combo_image_builder_spec.rb`.

- [x] **POLYGLOT-TEST-009** — When the base agent image is rebuilt on a host,
  previously built combo images SHALL be treated as stale: the next
  provisioning use of a combo tag whose recorded base digest no longer matches
  the current base image SHALL rebuild the combo against the new base.
  Rebuilds SHALL also be available eagerly (rake task / build script) so
  operators can cascade after a base bump without waiting for a run. The
  eager sweep SHALL enumerate only tags the language-layer matrix can compose,
  so other `paid-agent:` tags present on a backend (the base image alias, an
  operator's own build) neither fail the sweep nor are rebuilt.
  *Code:* `app/services/containers/combo_image_builder.rb`,
  `lib/tasks/containers.rake`, `scripts/build-agent-image.sh`.
  *Test:* `spec/services/containers/combo_image_builder_spec.rb`,
  `spec/tasks/containers_rake_spec.rb`.

- [x] **POLYGLOT-TEST-010** — The system SHALL periodically prune combo image
  tags that no active project resolves to and no running container uses, once
  they have been unreferenced past a retention window (30 days). The base
  image, and any other `paid-agent:` tag the builder did not produce, SHALL
  never be pruned by this job.
  *Code:* `app/jobs/agent_combo_image_cleanup_job.rb`,
  `config/initializers/good_job.rb`.
  *Test:* `spec/jobs/agent_combo_image_cleanup_job_spec.rb`.

- [D] **POLYGLOT-TEST-005** — Swift support SHALL remain limited to
  Linux-capable Swift Package Manager projects; iOS-only Xcode targets are out
  of scope for this segment.
