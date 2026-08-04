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

## What this is not

- **Not structured multi-language test parsing.** Exit-code-only result handling
  remains the current contract.
- **Not a claim that every language runtime is available today.** The segment
  exists because those runtimes still need explicit implementation work.
- **Not iOS build support.** Swift support is scoped to Linux-capable Swift
  Package Manager projects rather than Xcode/iOS-only targets.
