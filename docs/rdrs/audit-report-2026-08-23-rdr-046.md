# RDR-046 Audit Report — 2026-08-23 Final Validation Closeout

- **RDR**: [RDR-046: Polyglot Language Detection and Test Execution](RDR-046-polyglot-language-detection-and-test-execution.md)
- **Audit date**: 2026-08-23
- **Closeout issue**: [#3597](https://github.com/viamin/paid/issues/3597)
- **Prior reconciliation**: [#3164](https://github.com/viamin/paid/issues/3164) (PR #3211, merged 2026-08-04) — filed the three focused follow-ups below
- **Follow-up issues verified**: [#3207](https://github.com/viamin/paid/issues/3207) (PR #3252, merged 2026-08-06), [#3208](https://github.com/viamin/paid/issues/3208) (PR #3263, merged 2026-08-06), [#3209](https://github.com/viamin/paid/issues/3209) (PR #3258, merged 2026-08-06) — all closed
- **Follows**: the [RDR Closeout Checklist](closeout-checklist.md)
- **Conclusion**: **Partially Implemented** (unchanged verdict; scope shifted). All three follow-up issues shipped real code and passing tests, but the audit found a production-blocking integration gap that the closed issues and their specs do not catch: the detection service writes to a different persisted column than the one the command-routing and image-resolution consumers read. Two focused child issues are filed: [#3612](https://github.com/viamin/paid/issues/3612) (critical) and [#3613](https://github.com/viamin/paid/issues/3613).

## Validation Evidence

```console
$ bundle exec rspec \
    spec/services/prompts/language_commands_spec.rb \
    spec/services/containers/image_resolver_spec.rb \
    spec/services/containers/quality_hooks_spec.rb \
    spec/services/projects/detect_repo_profile_spec.rb \
    spec/services/projects/repo_profile_spec.rb \
    spec/jobs/enqueue_knowledge_collection_job_spec.rb \
    spec/models/project_spec.rb
462 examples, 0 failures
```

```console
$ bundle exec rails runner '
project = Project.new(primary_language: "ruby", repo_profile: {
  "languages" => %w[ruby elixir],
  "test_languages" => %w[ruby elixir],
  "framework" => "phoenix"
})
puts "project.test_languages (via repo_profile): #{project.test_languages.inspect}"
puts "project.language_profile (raw column): #{project.language_profile.inspect}"
puts "Prompts::LanguageCommands.test_languages: #{Prompts::LanguageCommands.test_languages(project).inspect}"
puts "Prompts::LanguageCommands.test_commands_for: #{Prompts::LanguageCommands.test_commands_for(project).inspect}"
puts "Containers::ImageResolver.resolve: #{Containers::ImageResolver.resolve(project)}"
'
project.test_languages (via repo_profile): ["ruby", "elixir"]
project.language_profile (raw column): {}
Prompts::LanguageCommands.test_languages: ["ruby"]
Prompts::LanguageCommands.test_commands_for: ["bundle exec rspec"]
Containers::ImageResolver.resolve: paid-agent:latest
```

The specs all pass because every polyglot spec for `Prompts::LanguageCommands`,
`Containers::ImageResolver`, and `Containers::QualityHooks` sets
`language_profile` directly via factory/`update!` calls — none of them run
`Projects::DetectRepoProfile` and then exercise command/image resolution
against its actual output. The `rails runner` reproduction above uses the real
persistence shape the detection service writes (`repo_profile`) and shows the
consumers never see it.

## Criterion-by-Criterion Findings

### Criterion 1: Unified language/framework detection, persisted at import time

**Status**: Implemented.

- `Projects::DetectRepoProfile` (`app/services/projects/detect_repo_profile.rb`)
  scans the cloned repo for marker files covering all 8 target languages
  (Ruby, JavaScript, TypeScript, Python, Go, Rust, Elixir, Swift — lines
  52-95) and layers framework detection via
  `Screenshots::DetectFramework.detect_framework_only` (local file scan, no
  GitHub API call).
- `Projects::RepoProfileConfig` (`app/services/projects/repo_profile_config.rb`)
  parses an optional `.paid.yml` manifest and merges it over detection
  (manifest wins for `languages`/`test_languages`/`framework`) —
  `detect_repo_profile.rb:19-30`.
- Hooked into project import: `EnqueueKnowledgeCollectionJob#perform` calls
  `detect_repo_profile` (`app/jobs/enqueue_knowledge_collection_job.rb:25-36,
  49-61`) inside the same worktree checkout used by the existing knowledge
  collectors — no new container lifecycle, matching Discovery 6 of the RDR.
  Tagged `@spec POLYGLOT-TEST-002`.
- Persistence: `projects.repo_profile` (jsonb, `db/migrate/20260805150519_add_repo_profile_to_projects.rb`)
  stores `languages`, `test_languages`, `framework`, `confidence`,
  `detected_at`, `source`, `marker_files`, `manifest_path` —
  `Projects::RepoProfile.normalize` (`app/services/projects/repo_profile.rb`).
- `Project#effective_repo_profile` / `#detected_languages` / `#test_languages`
  / `#detected_framework` (`app/models/project.rb:738-760`) give consumers a
  single read path, falling back to the shipped `primary_language` shortcut
  when no profile exists, preserving pre-existing behavior.
- Re-detection: runs on every `EnqueueKnowledgeCollectionJob` invocation
  (project creation and repo re-sync both enqueue this job).

**Tests**: `spec/services/projects/detect_repo_profile_spec.rb` (multi-language
detection, manifest override, framework detection),
`spec/services/projects/repo_profile_spec.rb` (normalization),
`spec/jobs/enqueue_knowledge_collection_job_spec.rb` (import hook),
`spec/models/project_spec.rb` (reader methods). All pass — see Validation
Evidence.

**Verdict**: Satisfied. This closes the RDR's Phase 1 gap ("no shared
persisted repo-derived polyglot/framework profile") called out in the prior
2026-08-04 status.

---

### Criterion 2: Command map expansion (Elixir, Swift, DB-dependent guard)

**Status**: Implemented.

- `LANGUAGE_TEST_COMMANDS` / `LANGUAGE_LINT_COMMANDS`
  (`app/services/prompts/language_commands.rb:13-31`) cover all 8 languages,
  including `"elixir" => "mix test"` / `"mix credo --strict"` and
  `"swift" => "swift test"` / `"swift format lint --recursive ."`.
- `Containers::QualityHooks::DB_DEPENDENT_TEST_LANGUAGES`
  (`app/services/containers/quality_hooks.rb:13`) is `%w[ruby elixir]`,
  extending the DB guard to Phoenix/Ecto per the RDR's requirement.

**Tests**: `spec/services/prompts/language_commands_spec.rb` (command map
coverage for all 8 languages), `spec/services/containers/quality_hooks_spec.rb`
(Elixir DB-gating). Pass — see Validation Evidence.

**Verdict**: Satisfied.

---

### Criterion 3: Polyglot command routing (multiple languages per project)

**Status**: Partial — implemented but effectively dead in production (see
[Gap 1](#gap-1-critical-language_profile-and-repo_profile-are-two-disconnected-columns)).

- `Prompts::LanguageCommands.test_languages` / `.test_commands_for` /
  `.lint_commands_for` (`app/services/prompts/language_commands.rb:62-96`)
  correctly resolve one command per configured test language and join them
  for prompt display (`.format_for_prompt`, joins with `", then "`).
- `Containers::QualityHooks#install_quality_hooks`
  (`app/services/containers/quality_hooks.rb:15-34`) resolves per-language
  lint/test command arrays and passes them to
  `Containers::GitOperations#install_git_hooks`
  (`app/services/containers/git_operations.rb:380-381`), whose
  `pre_commit_script` (`git_operations.rb:1284-1299`) runs each command in its
  own availability-checked block — genuinely polyglot pre-commit hook
  generation.
- **The break**: `Prompts::LanguageCommands.test_languages` sources the
  language set from `profile_languages(project)`
  (`language_commands.rb:99-105`), which reads `project.language_profile` —
  **not** `project.test_languages` (the model reader that correctly resolves
  through `repo_profile`, `app/models/project.rb:752-754`). Since nothing in
  production ever writes `language_profile` (see Gap 1), `profile_languages`
  always returns `[]`, and `test_languages` always falls back to
  `[detected_language(project)]` — the single-language behavior RDR-046 was
  written to replace.

**Tests**: `spec/services/prompts/language_commands_spec.rb:100-145` and
`spec/services/containers/quality_hooks_spec.rb:95-137` all pass, but every
one sets `language_profile` directly via `create(:project, language_profile:
{...})` / `project.update!(language_profile: {...})` — none exercise the real
`Projects::DetectRepoProfile` → `repo_profile` → command-resolution path
end-to-end, so the passing suite does not prove polyglot routing works for a
project detected the way production actually detects it.

**Verdict**: Partial. The routing logic and pre-commit multi-command
generation are correct; the wiring from real detection output to that logic
is broken. Tracked by [#3612](https://github.com/viamin/paid/issues/3612).

---

### Criterion 4: Docker image resolution from project language/runtime requirements

**Status**: Partial — resolver logic shipped and correct in isolation, but
(a) has the same `language_profile` disconnect as Criterion 3, and (b) the
combo images it resolves to are never built.

- `Containers::ImageResolver` (`app/services/containers/image_resolver.rb`)
  maps a language set to `paid-agent:latest` (base) or a sorted combo tag
  (`paid-agent:<sorted-tokens>`) for Go/Rust/Elixir/Swift, with a `strict:`
  mode that raises `UnsupportedRuntimeError` instead of silently falling back
  (`image_resolver.rb:86-92`, satisfies POLYGLOT-TEST-006).
- All 5 previously hardcoded `"paid-agent:latest"` call sites now resolve
  through the catalog/resolver chain: `Containers::Provision`
  (`app/services/containers/provision.rb:1445-1457`, via
  `Containers::RuntimeImageSelector` → `ImageResolver.resolve(project)`),
  `Containers::ProvisionForChat`, `Knowledge::ContainerizedRunner`,
  `Knowledge::EmbeddingRunner`, `Knowledge::AnalysisRunner` (all default to
  `ImageResolver.base_image` per the RDR's "chat/knowledge don't need
  project-specific runtimes" design principle).
- **Gap (a) — same disconnect as Criterion 3**: `ImageResolver#profile_languages`
  (`image_resolver.rb:123-128`) also reads `project.language_profile` instead
  of `project.detected_languages`/`project.test_languages`. Reproduced above:
  a project with `repo_profile` correctly identifying `ruby` + `elixir`
  resolves to `paid-agent:latest`, not an Elixir-capable combo tag.
- **Gap (b) — combo images are never built**: no
  `docker/agent/languages/{elixir,go,rust,swift}.dockerfile` exist (only the
  single monolithic `docker/agent/Dockerfile`); no code calls
  `Docker::Image.build`; `scripts/build-agent-image.sh` has no Elixir/Go/Rust
  path. `Containers::ImageResolver` can compute a tag like
  `paid-agent:elixir-node-python-ruby` that no build pipeline in this
  repository ever produces.

**Tests**: `spec/services/containers/image_resolver_spec.rb` (tag resolution
logic, unsupported-runtime handling — all against a project test double, not
real detection output). Pass — see Validation Evidence.

**Verdict**: Partial. Tracked by
[#3612](https://github.com/viamin/paid/issues/3612) (wiring) and
[#3613](https://github.com/viamin/paid/issues/3613) (actually building the
images).

---

### Criterion 5: Manifest support (`.paid.yml`)

**Status**: Implemented (ahead of the RDR's own sequencing — the RDR scoped
this as Phase 4, "independent, can start after Phase 1").

- `Projects::RepoProfileConfig` parses `.paid.yml` from the repo root and
  normalizes `languages.all`, `languages.test`, and `framework`.
  `Projects::DetectRepoProfile#call` merges manifest fields over detected
  values field-by-field (manifest wins when present, detection fills gaps) —
  matching the RDR's merge semantics.

**Tests**: `spec/services/projects/detect_repo_profile_spec.rb` (manifest
override case). Pass.

**Verdict**: Satisfied for the scope that shipped (language/test-language/
framework overrides). The RDR's fuller manifest schema
(`runtime_versions`, `test_command`, `lint_command`, `setup_steps`) did not
ship, but no follow-up issue claimed that scope, so it is not treated as a
broken promise here — noting it for future manifest work rather than filing
a new gap issue, since nothing regressed and no issue referenced it as done.

---

### Criterion 6: Consumer integration (badge, app startup, screenshot framework detection)

**Status**: Implemented for the consumers actually exercised.

- `Screenshots::RuntimePlan#detected_framework` and `#application_start_command`
  (`app/services/screenshots/runtime_plan.rb:54-75`) read
  `project.detected_framework` first (which resolves through `repo_profile`),
  falling back to local file detection — this is the RDR-045 preview/runtime
  path reading the shared profile, as the RDR's Phase 5 intended.
- `Screenshots::DetectFramework` was already local-file-based (no GitHub API
  fetch) and is reused directly by `Projects::DetectRepoProfile`, so the
  "fragmented across 6+ services" problem is meaningfully reduced: detection
  now runs once via one shared framework detector, not via a second GitHub
  API-driven code path.

**Verdict**: Satisfied for the parts of Phase 5 exercised by shipped code.

## Gaps

### Gap 1 (critical): `language_profile` and `repo_profile` are two disconnected columns

Filed as [#3612](https://github.com/viamin/paid/issues/3612).

`db/migrate/20260805150519_add_repo_profile_to_projects.rb` (PR #3252,
issue #3207) and `db/migrate/20260806013539_add_language_profile_to_projects.rb`
(PR #3258, issue #3209) each add a separate jsonb column to `projects`, one
day apart, in the same follow-up chain. PR #3258 actually merged *before*
PR #3252 that same day (04:58 vs. 10:49 UTC), so at the time #3258 was
written, `repo_profile` did not yet exist on `main` — its author added a new
column instead. Once #3252 merged, nobody reconciled the two: detection
writes `repo_profile`; `Prompts::LanguageCommands` and
`Containers::ImageResolver` read `language_profile`. The model's own reader
methods (`Project#test_languages` etc.) correctly use `repo_profile`; only
these two consumers use the dead column. This is exactly the anti-pattern the
closeout checklist's "issue closed → RDR implemented" warning describes:
each of #3207/#3208/#3209 individually shipped real code and green tests,
and the cross-issue integration gap between them was invisible to any single
issue's test suite.

### Gap 2: Docker combo images are never built

Filed as [#3613](https://github.com/viamin/paid/issues/3613).

`Containers::ImageResolver` computes a correct combo tag, but no Dockerfile,
build script, or job in the repository produces an image with that tag for
Elixir, Go, Rust, or Swift. RDR-046 Phase 3 ("Docker Combo Image System")
scoped this explicitly (language-layer Dockerfiles, lazy build-on-first-use,
cache invalidation, cleanup); issue #3208's own acceptance criteria did not
require it, so #3208 closing did not regress anything, but full Phase 3 of
the RDR remains unshipped independent of Gap 1.

## Conclusion

RDR-046 stays **Partially Implemented**. Detection (Phase 1) and the command
map / pre-commit multi-command mechanics (part of Phase 2) are genuinely
done and well-tested. The remaining gap has shifted: it is no longer "no
shared profile exists" (2026-08-04 status) — it is "the shared profile exists
and is correctly populated, but two of its three consumers read a different,
empty column, and the resolved combo images are never built." Both gaps are
now filed as independently pickable, non-`planning`-labeled issues:
[#3612](https://github.com/viamin/paid/issues/3612) (critical — restores the
actual polyglot behavior RDR-046 promises) and
[#3613](https://github.com/viamin/paid/issues/3613) (Docker combo image
build pipeline). Re-run this closeout once both land.
