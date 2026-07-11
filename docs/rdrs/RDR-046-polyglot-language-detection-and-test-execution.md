# RDR-046: Polyglot Language Detection and Test Execution

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-07-11
- **Status**: Draft
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: #2845 (Phoenix detection), #2891 (Project type badge), #2844 (Live preview epic)
- **Related RDRs**: [RDR-004](RDR-004-container-isolation.md) (Container Isolation), [RDR-013](RDR-013-code-quality-backpressure.md) (Code Quality Backpressure — Superseded), [RDR-020](RDR-020-service-container-architecture.md) (Service Container Architecture), [RDR-035](RDR-035-style-guide-evolution.md) (Style Guide Evolution), [RDR-045](RDR-045-live-web-app-preview-agent-verification.md) (Live Web App Preview)
- **Related Tests**: `spec/services/prompts/language_commands_spec.rb`, `spec/services/containers/quality_hooks_spec.rb`, `spec/services/projects/`

## Implementation Status

Draft. Not implemented. Language detection is a stub (`Project` has no `detected_language` method or column — every project defaults to Ruby). The Docker agent image is monolithic with no per-language selection. The test command map includes 6 languages but none are reachable because detection never returns a non-Ruby result. Elixir and Swift are entirely unsupported.

## Problem Statement

Paid's code review bot left this comment on a Phoenix/Elixir PR ([color_matching#25](https://github.com/viamin/color_matching/pull/25#pullrequestreview-4675606278)):

> I could not run `mix test` to confirm here (Elixir isn't available in this review environment).

This is the visible symptom of a system-wide gap: the entire multi-language test execution pipeline is non-functional.

1. **Language detection is a stub.** `Prompts::LanguageCommands.detected_language(project)` checks `project.respond_to?(:detected_language)` — but `Project` never defines this method and has no corresponding column. Every project silently defaults to `"ruby"`, receiving `bundle exec rspec` as its test command regardless of actual language.

2. **The command map is dead code for 5 of 6 languages.** `LANGUAGE_TEST_COMMANDS` maps Ruby, JavaScript, TypeScript, Python, Go, and Rust — but since detection always returns Ruby, the other 5 entries are unreachable. Elixir and Swift are absent entirely.

3. **The Docker agent image is monolithic and incomplete.** `paid-agent:latest` bundles Ruby, Node, and Python, but lacks Erlang/Elixir, Go, Rust, and Swift. Every container uses the same hardcoded image reference (`"paid-agent:latest"` in 5 locations) with no selection logic.

4. **Detection is fragmented across 6+ services.** `Screenshots::DetectFramework`, `Screenshots::FrameworkPatterns`, `ContainerCapture#application_start_command`, `StyleGuides::DetectLanguage`, `Knowledge::Collectors::LanguageStatsCollector`, and `Prompts::LanguageCommands` all perform overlapping but inconsistent language/framework detection, storing results in different places (or not at all).

5. **Open issues are blocked.** #2845 (Phoenix detection) needs a detection system to build on. #2891 (project type badge) needs persisted detection results. Both are P1.

Requirements:

- Detect all languages present in a repo at import time and persist the result with user override
- Detect framework alongside language in a unified pass — subsume #2845's planned additions
- Support 8 initial languages: Ruby, JavaScript, TypeScript, Python, Go, Rust, Elixir, Swift
- Build Docker images per language combination using layer caching
- Map each language to correct test/lint commands and inject into agent prompts and pre-commit hooks
- Expand database-dependent test guard beyond Ruby (e.g., Elixir/Phoenix)
- Support an optional repo-side manifest that overrides or supplements detection
- Feed unified detection to badge (#2891), app startup (#2845), and review bot prompt
- Code review bot stays LLM-only — injects correct test command into prompt but does not execute tests

## Context

### Background

Paid already has substantial detection-adjacent infrastructure. `Knowledge::Collectors::LanguageStatsCollector` runs `scc` inside a container at project import and produces per-language line/file counts — but stores them as `KnowledgeArtifact` records that are never read back for test command selection. `Screenshots::DetectFramework` (816 lines) scores frameworks by fetching `Gemfile` and `package.json` from the GitHub API. `ContainerCapture#application_start_command` checks for `bin/dev`, `bin/rails`, `manage.py`, and `package.json` to determine how to start a web app. None of these systems talk to each other or feed into test execution.

The quality hooks system (`Containers::QualityHooks`) installs a git pre-commit hook inside agent containers. It looks up test and lint commands from `LANGUAGE_TEST_COMMANDS` / `LANGUAGE_LINT_COMMANDS` based on the detected language, then writes a shell hook that runs those commands before each commit. A database-dependent guard (`DB_DEPENDENT_TEST_LANGUAGES = %w[ruby]`) disables the test command when no PostgreSQL container is running, preventing infinite commit loops. This system is architecturally sound — it just receives the wrong language input.

### Technical Environment

- **Container provisioning**: `Containers::Provision` creates Docker containers with a hardcoded image (`paid-agent:latest`). The image is built by `scripts/build-agent-image.sh` (214 lines) which compiles Ruby from source, installs Node via binary tarball, and adds Python via apt. No infrastructure exists for building Docker images programmatically from Ruby — `Docker::Image.create` is only used for pulling.
- **Project import**: `ProjectsController#create` saves the project, then `EnqueueKnowledgeCollectionJob` clones the repo and runs knowledge collectors inside a container. This is the natural hook point for language detection — the repo is already cloned and collectors already run.
- **Agent image**: `docker/agent/Dockerfile` (384 lines) builds on `ubuntu:24.04`. It installs Ruby 3.4.8, Node.js 22.13.0, Python 3, PostgreSQL client 16, plus agent CLIs (Claude Code, Codex, Gemini, etc.) and tools (ast-grep, scc, shellcheck). The image is ~2-3GB.
- **Quality hooks**: `Containers::QualityHooks` (concern mixed-in to Temporal activities) calls `Prompts::LanguageCommands.detected_language` → looks up commands → installs git hooks via `Containers::GitOperations#install_git_hooks`.
- **Pre-commit requirements**: `PreCommitRequirement` model supports check types (`shell_command`, `test_suite`, `coverage`, `security_scan`, `mutation_test`) with resolution hierarchy (project > user > account). Default at project creation seeds a disabled Ruby-only mutation testing requirement.
- **Existing detection systems**:
  - `Screenshots::DetectFramework` — GitHub API file fetch + scoring (Rails, Next.js, Django, generic)
  - `Screenshots::FrameworkPatterns` — file path pattern registry (rails, nextjs, django, generic)
  - `ContainerCapture#application_start_command` — local file existence checks (bin/dev, bin/rails, manage.py, package.json)
  - `StyleGuides::DetectLanguage` — keyword scoring of style guide content text
  - `Knowledge::Collectors::LanguageStatsCollector` — `scc` output stored as KnowledgeArtifact
  - `Prompts::LanguageCommands` — static hash lookup, always defaults to Ruby

## Research Findings

### Investigation Process

1. Analyzed the `color_matching` PR review where the bot noted Elixir was unavailable — confirmed the bot is LLM-only and cannot run tests for any language.
2. Traced the full test command resolution path: `LanguageCommands.detected_language` → `LANGUAGE_TEST_COMMANDS` lookup → `QualityHooks.install_quality_hooks` → `GitOperations.install_git_hooks` → `pre_commit_script`.
3. Confirmed `Project` has no `detected_language` column in `db/schema.rb` and no method definition — the `respond_to?` guard always returns false.
4. Read `docker/agent/Dockerfile` (384 lines) and `scripts/build-agent-image.sh` (214 lines) to understand image build — confirmed monolithic, no modular layer support.
5. Traced image selection in `Containers::Provision` — confirmed hardcoded `"paid-agent:latest"` with no per-project selection.
6. Examined all 6 existing detection systems — confirmed fragmentation and inconsistency.
7. Traced project import flow through `ProjectsController#create` → `EnqueueKnowledgeCollectionJob` — confirmed this is the natural detection hook point.
8. Estimated Docker layer storage costs for per-language-combination images.

### Key Discoveries

**Discovery 1 — `LanguageStatsCollector` already detects languages but discards the result.** The collector runs `scc` inside a container at import time and produces accurate per-language breakdowns. The data is stored as `KnowledgeArtifact` records but never read back for test command selection, image selection, or badge display. The detection data already exists — it is just not wired to consumers.

**Discovery 2 — The image is hardcoded in 5 locations with no selection logic.** `Containers::Provision` (line 139), `Containers::ProvisionForChat` (line 28), `Knowledge::ContainerizedRunner` (line 42), `Knowledge::EmbeddingRunner` (line 16), and `Knowledge::AnalysisRunner` (line 24) all reference `"paid-agent:latest"`. The only override mechanism is a keyword argument to `Containers::Provision.new` — but no caller passes one.

**Discovery 3 — No Docker image build infrastructure exists in Ruby.** `Docker::Image.create` is only used for pulling (`fromImage`), never building. All image building is shell scripts and CI workflows. Building combo images requires either extending the shell script or adding Docker API build calls.

**Discovery 4 — Docker layer caching bounds storage cost.** A shared base layer (~2-3GB) deduplicates across all combo images. Each language runtime is an incremental layer (~0.5-1.5GB). Total incremental storage for all 8 languages: ~6.5GB on top of the existing base — not 6.5GB multiplied by N images. The practical combination count is small (10-15 variants).

**Discovery 5 — The quality hooks system is architecturally sound.** The pre-commit hook installation, command validation (`SAFE_WORD_PATTERN`), and DB-dependent guard all work correctly. The system just receives the wrong language input. Fixing detection automatically fixes test command selection, pre-commit hooks, and prompt injection.

**Discovery 6 — `EnqueueKnowledgeCollectionJob` is the ideal detection hook point.** It already runs at project creation, already clones the repo, and already runs collectors inside a container. Adding a language detection collector here requires no new infrastructure — just a new collector and a persistence target on the project.

**Discovery 7 — Swift on Linux is viable for `swift test` but limited.** The Swift toolchain runs on Linux (Ubuntu/Debian). `swift test` works for Swift Package Manager projects. However, iOS app targets (`.xcodeproj` with UIKit/SwiftUI) cannot compile or test on Linux. The RDR should support Swift Package Manager projects and clearly exclude iOS-only targets.

**Discovery 8 — RDR-013's multi-language parser design was never implemented.** RDR-013 (Code Quality Backpressure, status: Superseded) described structured test output parsers for rspec, pytest, jest, gotest, and cargo_test. The actual `QualityFeedbackService` was stripped to mutation-testing-only. This RDR does not revive structured parsing — test results stay exit-code-only.

## Proposed Solution

### Approach

Build a unified detection system that runs once at project import, persists results on the project, and serves all consumers through a single read path. Layer on a Docker combo image system that builds and caches per-language-combination images using Docker's native layer sharing. Add an optional repo-side manifest for precision and polyglot configuration.

### Design Principles

- **One detection pass, many consumers.** Language and framework are detected once at import and persisted. Test commands, image selection, app startup, badge, and review prompt all read from the same result. No consumer re-detects independently.
- **Reuse what exists.** `LanguageStatsCollector` already produces language data via `scc`. `ContainerCapture#application_start_command` already checks for marker files. Unify these into a single detection service rather than building a fourth parallel system.
- **Layered images, not fat images.** Docker layer caching means incremental storage cost per language, not per image. A Phoenix project and a Go project share the ~2GB base layer. Build lazily — first use triggers the build, subsequent uses reuse the cached tag.
- **Detection is primary, manifest is escape hatch.** Zero-config for new projects. The manifest exists for precision (exact versions, custom commands) and polyglot configuration (which languages to test). When both exist, manifest wins for overlapping fields.
- **Fix forward, don't revive superseded designs.** RDR-013's structured test parsers stay superseded. Test results stay exit-code-only. This RDR fixes detection and execution, not result parsing.
- **Swift Package Manager only.** Swift on Linux supports `swift test` for SPM projects. iOS app targets are excluded with a clear message, not silently broken.

### Technical Design

#### Unified Language Detection

A new service (`Projects::DetectLanguageFramework`) performs detection by scanning the cloned repo for marker files and dependency manifests. This runs inside `EnqueueKnowledgeCollectionJob` alongside existing knowledge collectors — no new container lifecycle needed.

**Marker file detection matrix:**

| Language | Marker files | Framework detection |
|---|---|---|
| Ruby | `Gemfile`, `*.gemspec` | Rails (`rails` in Gemfile), Hanami |
| JavaScript | `package.json` (no TS) | Next.js, React, Vue, Express |
| TypeScript | `package.json` + `tsconfig.json` | Next.js, React, Vue, NestJS |
| Python | `pyproject.toml`, `setup.py`, `requirements.txt` | Django, FastAPI, Flask |
| Go | `go.mod` | — |
| Rust | `Cargo.toml` | — |
| Elixir | `mix.exs` | Phoenix (`phoenix`/`phoenix_live_view` in deps) |
| Swift | `Package.swift` | — (SPM only; `.xcodeproj` excluded — iOS targets cannot compile on Linux) |

**Persistence:** A new JSONB column `language_profile` on `projects` stores:

```
{
  "languages": ["elixir", "javascript"],
  "framework": "phoenix",
  "confidence": 0.95,
  "detected_at": "2026-07-11T...",
  "test_languages": ["elixir"],          // user-configured subset for polyglot
  "override": null,                       // user override or manifest data
  "marker_files": ["mix.exs", "package.json"]
}
```

This subsumes `screenshot_settings["detection"]` (currently where `DetectFramework` stores its result) and the `detected_language` stub on `Project`.

**Re-detection:** Triggered on repo sync (same job that re-runs knowledge collectors) or manually from project settings. User overrides survive re-detection unless explicitly cleared.

**Relationship to #2845:** Instead of #2845 adding Phoenix detection to `Screenshots::DetectFramework`, the unified detection service detects Phoenix and stores the result. `Screenshots::DetectFramework` reads from `language_profile` rather than performing its own GitHub API fetch. `ContainerCapture#application_start_command` reads from `language_profile` rather than checking file existence.

#### Docker Combo Image System

**Language layer Dockerfiles:** Modular Dockerfile fragments under `docker/agent/languages/`:

```
docker/agent/
├── Dockerfile                    # base (OS + Ruby + Node + Python + agent CLIs)
├── languages/
│   ├── elixir.dockerfile         # Erlang/OTP + Elixir
│   ├── go.dockerfile             # Go toolchain
│   ├── rust.dockerfile           # Rust stable
│   └── swift.dockerfile          # Swift toolchain (Linux)
```

Each language layer `FROM`s the base image (or a prior combo) and installs only that language's toolchain.

**Tag convention:** `paid-agent:<sorted-language-set>`

- `paid-agent:ruby-node-python` (the current base, aliased as `paid-agent:latest` for backward compat)
- `paid-agent:elixir-node-ruby-python` (Phoenix project with JS assets)
- `paid-agent:go-ruby-node-python`
- `paid-agent:swift`

Tags use sorted, hyphen-joined language names for deterministic lookup.

**Image resolution service** (`Containers::ImageResolver`): Given a project's `language_profile`, computes the required image tag. Checks if the tag exists locally (`Docker::Image.all` or `docker inspect`). If missing, triggers a build via `Docker::Image.build` from the appropriate Dockerfile composition, then tags the result. Builds are logged for observability.

**Provision integration:** `Containers::Provision` calls `ImageResolver.resolve(project)` instead of using the hardcoded `"paid-agent:latest"`. The 5 hardcoded locations are updated to resolve through the image resolver, with knowledge collection and chat containers defaulting to the base image (they don't need project-specific runtimes).

**Image lifecycle:**

- **Build trigger:** First `Containers::Provision` call for a project whose language set has no matching tag.
- **Cache invalidation:** Base image patch bumps a version suffix (`paid-agent:ruby-node-python-v2`). Language layers rebuild against the new base. A `Rakefile` task or script triggers cascading rebuilds.
- **Cleanup:** Images with no project reference for 30 days are eligible for pruning. A scheduled GoodJob task performs cleanup.

#### Command Map Expansion

**`LANGUAGE_TEST_COMMANDS` and `LANGUAGE_LINT_COMMANDS` additions:**

| Language | Test command | Lint command |
|---|---|---|
| Elixir | `mix test` | `mix credo --strict` |
| Swift | `swift test` | `swift format lint --recursive .` |

**`DB_DEPENDENT_TEST_LANGUAGES` expansion:** Add `"elixir"` alongside `"ruby"`. Phoenix/Elixir projects typically require PostgreSQL for their test suite. The existing guard pattern (disable test command when no DB container is running) extends naturally.

**Polyglot command resolution:** For projects with multiple test-enabled languages, the pre-commit hook runs each language's test command in sequence. The prompt lists all enabled test commands.

#### Manifest Support

**Format: `.paid.yml`** (purpose-built, simpler than `devcontainer.json`):

```yaml
languages:
  primary: elixir
  test: [elixir, javascript]
framework: phoenix
runtime_versions:
  elixir: "1.16"
test_command: "mix test"
lint_command: "mix credo --strict"
setup_steps:
  - "mix deps.get"
  - "mix ecto.setup"
```

**Merge semantics:** Manifest fields override detected values. Fields absent from the manifest fall back to detection. This means a project can declare just `test_command` to override the default, or fully specify everything.

**Why `.paid.yml` over `devcontainer.json`:** Devcontainer spec carries assumptions about editor integration, feature metadata, and container lifecycle that Paid doesn't need. A purpose-built format is ~20 lines of YAML, easy to author, and doesn't conflict with repos that already have a devcontainer for their IDE. The parser is simple YAML — no JSON-with-features complexity.

#### Integration Points

| Consumer | Current source | After RDR-046 |
|---|---|---|
| Test/lint commands (`QualityHooks`) | `LanguageCommands.detected_language` (always Ruby) | `project.language_profile` → command map |
| Agent prompt (`BuildForIssue`, `BuildForPr`) | Same stub | Same `language_profile` → command map |
| Docker image selection (`Provision`) | Hardcoded `"paid-agent:latest"` | `ImageResolver.resolve(project)` |
| Badge (#2891) | Nothing | `project.language_profile["framework"]` |
| App startup (#2845) | `ContainerCapture#application_start_command` file checks | `language_profile["framework"]` → startup command lookup |
| Screenshot framework detection | `Screenshots::DetectFramework` GitHub API fetch | Reads `language_profile` (detection already done at import) |
| Knowledge base route collection | Separate collector per framework | Unified detection feeds route parser selection |

## Alternatives Considered

### Alternative 1: Single Polyglot Image

Build one fat image with all 8 runtimes pre-installed. Every container carries everything.

**Pros:** Simplest — one image, one tag, no selection logic. No build-on-demand infrastructure.
**Cons:** Image grows to ~8.5GB. Every container startup loads runtimes it doesn't need. Longer pull times for new Docker hosts. More attack surface.
**Rejected:** Storage savings from layer caching make combo images strictly better. The complexity of image resolution is modest compared to the operational cost of an 8.5GB image on every container.

### Alternative 2: Hybrid (Base + On-Demand Install)

Keep the current base image. Install additional runtimes at container startup via `apt-get`, `asdf`, or similar.

**Pros:** No image build infrastructure needed. Maximum flexibility — any runtime, any version.
**Cons:** Every container startup pays installation latency (1-5 minutes for Erlang/OTP). Network dependency — flaky apt mirrors break agent runs. Non-deterministic environments — different versions installed on different days.
**Rejected:** Combo images eliminate both the latency and the network dependency. The one-time build cost amortizes across all future containers with the same language set.

### Alternative 3: Project-Declared Manifest Only (No Detection)

Projects declare their runtime spec via manifest file. No auto-detection — the manifest is required.

**Pros:** Eliminates detection accuracy as a concern entirely. Projects own their environment spec.
**Cons:** Not zero-config. New projects must create a manifest before Paid can run their tests. Badge (#2891) has nothing to display for repos without a manifest. Adds friction to onboarding.
**Rejected:** Auto-detection handles the 90% case. The manifest is the escape hatch for the 10% that need precision, not a requirement for all.

### Alternative 4: Per-Language Images (One Image Per Language)

Build a separate image per language: `paid-agent:ruby`, `paid-agent:elixir`, `paid-agent:go`, etc.

**Pros:** Simplest image-to-language mapping. No combo logic.
**Cons:** Polyglot repos (Rails + React, Phoenix + JS assets) need multiple runtimes. Per-language images can't handle this without running two containers or falling back to install-on-demand. The combo approach naturally handles polyglot by including all needed language layers in one image.
**Rejected:** Combo images are a strict superset — they handle both single-language and polyglot repos.

## Trade-offs

### Positive Consequences

- **Multi-language projects finally work.** Elixir, Go, Rust, and Swift projects get correct test commands, correct runtimes, and correct pre-commit hooks — automatically.
- **Detection unification reduces maintenance.** Six fragmented detection paths collapse into one. Adding a new framework means one new entry in the detection matrix, not changes to 3-4 services.
- **Adding a 9th language is data-only.** A new marker file rule, a new command map entry, and a new Dockerfile layer. No architectural changes.
- **#2845 and #2891 unblock naturally.** Both consume the unified detection result rather than building parallel systems.
- **Docker layer caching keeps storage bounded.** ~6.5GB incremental for all 8 languages, shared across all projects via layer deduplication.

### Negative Consequences

- **Image build lifecycle is new operational surface.** Building, tagging, cache invalidation, and cleanup of combo images is ongoing work that doesn't exist today. The build-on-first-use pattern means the first agent run for a new language combination is slower (image build time).
- **Detection accuracy is now load-bearing.** Wrong detection means wrong image, wrong test commands, wrong pre-commit hooks. The user override and manifest escape hatch mitigate this, but the auto-detection must be good for the common case.
- **Swift on Linux is a constrained subset.** Only Swift Package Manager projects are supported. iOS app projects (the majority of Swift development) cannot compile or test on Linux. This must be communicated clearly, not silently broken.
- **Mutation testing stays Ruby-only.** RDR-036 (mutation testing for AI-generated tests) remains scoped to Ruby/mutant. This RDR does not extend mutation testing to other languages.
- **Not a CI replacement.** Paid runs the project's test suite via pre-commit hooks and prompt-injected commands, not a general-purpose CI engine. Structured test output parsing (pass/fail counts, coverage extraction) from RDR-013 stays superseded.
- **Two code paths (detection + manifest).** The merge logic adds complexity. Testing must cover: detection only, manifest only, both with conflicts, manifest overriding partial detection.

### Risks

- **`scc` output may not map cleanly to marker-file detection.** `scc` counts lines by language, which may include config files, vendored code, or generated artifacts. Marker-file detection (checking for `mix.exs`, `go.mod`) is more precise for determining the primary language. The detection service should use marker files as the primary signal and `scc` output as secondary corroboration.
- **Docker image build inside a container environment.** If Paid itself runs inside a Docker container (devcontainer), building images requires Docker-in-Docker or socket mounting. The current setup mounts the Docker socket, so builds should work — but this needs validation for remote Docker (RDR-019).
- **Elixir/Erlang compilation time.** Installing Erlang/OTP from source can take 10-15 minutes. Pre-compiled packages (Erlang Solutions repository) should be used instead of source compilation in the language layer Dockerfile.

## Implementation Plan

### Phase 1: Detection Foundation

**Goal:** Detect languages and framework at import, persist on project, surface as badge.

- New migration: add `language_profile` JSONB column to `projects`
- New service: `Projects::DetectLanguageFramework` — scans repo for marker files, identifies languages and framework
- Hook into `EnqueueKnowledgeCollectionJob` — run detection alongside existing collectors
- `Project#language_profile` reader method (replaces the `detected_language` stub)
- Badge display on project tiles (#2891)
- User override via project settings (write to `language_profile["override"]`)

**Unblocks:** #2891 (badge)

### Phase 2: Command Map and Agent Execution

**Goal:** Correct test/lint commands flow to agent containers and prompts.

- Add Elixir and Swift to `LANGUAGE_TEST_COMMANDS` / `LANGUAGE_LINT_COMMANDS`
- Add `"elixir"` to `DB_DEPENDENT_TEST_LANGUAGES`
- Wire `LanguageCommands` to read from `project.language_profile` instead of the stub
- Wire `QualityHooks` to handle polyglot (multiple test commands)
- Wire `BuildForIssue` and `BuildForPr` prompt builders to inject correct commands
- Polyglot: run test suites for all `test_languages` in sequence

**Unblocks:** Correct test commands for all 8 languages in agent runs

### Phase 3: Combo Image System

**Goal:** Agent containers start with the correct runtime for the project's language(s).

- Language layer Dockerfiles: `docker/agent/languages/{elixir,go,rust,swift}.dockerfile`
- New service: `Containers::ImageResolver` — maps language set to image tag, triggers lazy build
- Update `Containers::Provision` to resolve image via `ImageResolver` instead of hardcoded constant
- Update remaining 4 hardcoded image references (chat, knowledge runners)
- Image build logging and observability
- Scheduled cleanup job for stale images

**Unblocks:** Actual test execution for Elixir, Go, Rust, Swift in agent containers

### Phase 4: Manifest Support

**Goal:** Projects can override detection with a `.paid.yml` manifest.

- Define `.paid.yml` schema (languages, test_command, lint_command, runtime_versions, setup_steps)
- New parser: `Projects::ManifestParser` — reads `.paid.yml` from repo
- Merge logic: manifest overrides detection, detection fills gaps
- Integration with `EnqueueKnowledgeCollectionJob` — manifest parsed alongside detection
- Project settings UI for viewing merged result

### Phase 5: Consumer Integration

**Goal:** All existing detection consumers read from the unified result.

- `Screenshots::DetectFramework` reads from `language_profile` instead of GitHub API fetch
- `ContainerCapture#application_start_command` reads from `language_profile` instead of file checks
- `Screenshots::FrameworkPatterns` reads from `language_profile` for pattern selection
- Knowledge base route collector uses detected framework for parser selection
- Update #2845 to consume unified detection (Phoenix detection comes free from Phase 1)

**Unblocks:** #2845 (Phoenix detection and startup)

### Sequencing Dependencies

```
Phase 1 (Detection) ──► Phase 2 (Commands) ──► Phase 3 (Images)
                  │                                    │
                  └──► Phase 5 (Integration) ◄────────┘
                  │
                  └──► Phase 4 (Manifest) [independent, can start after Phase 1]
```

Phase 2 and Phase 4 can proceed in parallel after Phase 1. Phase 3 depends on Phase 1 (needs language profile) but not Phase 2. Phase 5 depends on Phases 1 and 3.

## Validation

### Detection Accuracy

- Import the `color_matching` repo → detect Elixir + Phoenix with confidence > 0.8
- Import the `paid` repo → detect Ruby + Rails
- Import a polyglot repo (e.g., Rails API + React frontend) → detect both Ruby and JavaScript
- Import a Go-only repo → detect Go
- Import a repo with a `.paid.yml` manifest → manifest values override detection
- Re-sync after adding `mix.exs` to a previously Ruby-only repo → detect Elixir alongside Ruby

### Test Execution

- Elixir project: agent container has `mix` available, pre-commit hook runs `mix test`, prompt includes `mix test`
- Elixir project without PostgreSQL: test command is nil (DB guard), agent runs without commit loop
- Go project: agent container has `go` available, pre-commit hook runs `go test ./...`
- Swift SPM project: agent container has `swift` available, pre-commit hook runs `swift test`
- Swift iOS project (`.xcodeproj` only, no `Package.swift`): detection excludes Swift with a clear message
- Polyglot project: both Elixir and JavaScript test suites run in the pre-commit hook

### Docker Images

- First Elixir project: combo image `paid-agent:elixir-node-ruby-python` is built and tagged
- Second Elixir project: existing tag is reused, no rebuild
- Base image patch: cascading rebuild of all dependent combo images
- Stale image cleanup: image with no project references for 30 days is pruned

### Integration

- Badge shows "Phoenix / Elixir" for color_matching project
- Badge shows "Ruby on Rails" for paid project
- `ContainerCapture#application_start_command` returns `mix phx.server` for Phoenix project (reads from `language_profile`, not file checks)
- `Screenshots::DetectFramework` returns Phoenix without performing GitHub API fetch (reads from `language_profile`)
- Code review bot prompt includes `mix test` for Elixir project (not `bundle exec rspec`)
