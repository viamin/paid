---
parent: PAID
prefix: POLYGLOT-TEST
---

# Low-Level Design: Polyglot Test Execution

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the gap between the shipped Phoenix-specific preview/runtime
> foundations and the still-missing repo-wide language detection and test
> execution model.

## Purpose

RDR-046 is partially true in two directions:

- the repo still lacks a unified persisted language/runtime model that drives
  test commands, pre-commit hooks, image selection, and prompt guidance
- the preview/screenshot stack already shipped meaningful Phoenix and Elixir
  support, so "Ruby-only everywhere" is now stale

This segment records both the shipped foundations and the still-open
polyglot-execution work.

## Shipped Foundations

The current repository already supports Phoenix-specific behavior in the
preview/screenshot area:

- framework detection recognizes Phoenix
- route collection understands Phoenix router patterns
- project UI can label Elixir projects as `Phoenix / Elixir`
- preview/runtime startup code can recognize Phoenix when provisioning preview
  and screenshot flows

These are real shipped foundations, but they are local to preview/runtime
features rather than a shared project language contract.

## Active Gap

The missing product surface is the shared model RDR-046 describes:

- persisted project language/framework detection with override support
- one detection result consumed by prompts, quality hooks, preview/runtime, and
  image selection
- multi-language test/lint command selection beyond Ruby defaults
- runtime/image resolution for non-Ruby project combinations

## Agent Image Resolution

`Containers::ImageResolver` translates a project's persisted language profile
(`projects.repo_profile`, surfaced through `Project#test_languages` and
`Project#detected_languages`)
into the Docker agent image its execution containers should use
(POLYGLOT-TEST-004). The base image (`paid-agent:latest`) bundles Ruby, Node,
and Python — the runtimes every agent container needs. Projects whose detected
languages are a subset of those base runtimes resolve to the base image.
Projects requiring additional runtimes resolve to a combo image whose tag is the
sorted, hyphen-joined set of language tokens (`paid-agent:elixir-node-python-ruby`,
`paid-agent:go`, `paid-agent:swift`).

### Supported runtime matrix

| Language        | Token    | Image            |
| --------------- | -------- | ---------------- |
| Ruby            | `ruby`   | base             |
| JavaScript      | `node`   | base             |
| TypeScript      | `node`   | base             |
| Python          | `python` | base             |
| Go              | `go`     | combo layer      |
| Rust            | `rust`   | combo layer      |
| Elixir / Erlang | `elixir` | combo layer      |
| Swift           | `swift`  | combo layer      |

JavaScript and TypeScript both map to the `node` token because Node satisfies
both. A repo is considered "base-only" when its detected languages — after token
mapping — are a subset of `{node, python, ruby}`.

### Caller responsibilities

- **Agent execution** (`Containers::Provision`) resolves the image from the
  project's language profile, so a Go project runs in the Go combo image rather
  than the base. An explicit `image:` override still wins (e.g. pool reconnect,
  credential maintenance).
- **Warm pool** (`Containers::PoolManager`) warms and claims containers against
  the project-resolved image so a warmed container matches the image a run will
  actually request.
- **Chat and knowledge containers** always use the base image. They run
  analysis tooling and LLM calls, not the project's own test suite, so they
  never need project-specific runtimes.

### Unsupported runtimes

Languages outside the matrix (e.g. Java, Kotlin) have no agent image. The
resolver does not silently substitute the base image for an *extended* runtime
(Go/Rust/Elixir/Swift always get their combo tag); for genuinely unsupported
languages it falls back to the base image by default and exposes the unsupported
set for logging. Callers that must refuse execution in the wrong image pass
`strict: true`, which raises `Containers::ImageResolver::UnsupportedRuntimeError`
instead (POLYGLOT-TEST-006).

### Image builds, cache invalidation, and fallback

- **Build:** Combo images are built `FROM` the base image, each adding one
  language toolchain layer. The tag is deterministic from the language set, so
  the same project always resolves the same tag.
- **Cache invalidation:** A base-image patch is a new `paid-agent:latest`.
  Combo layers rebuild against the new base; because the tag embeds only the
  language set (not a version), consumers always resolve the latest build of
  that combo.
- **Fallback:** When a resolved combo image is absent on a host, Docker fails
  clearly at container creation (image not found) rather than silently running
  in the base image — the explicit failure is the contract.

## What this is not

- **Not structured multi-language test parsing.** Exit-code-only result handling
  remains the current contract.
- **Not a claim that every language runtime is available today.** The segment
  exists because those runtimes still need explicit implementation work.
- **Not iOS build support.** Swift support is scoped to Linux-capable Swift
  Package Manager projects rather than Xcode/iOS-only targets.
