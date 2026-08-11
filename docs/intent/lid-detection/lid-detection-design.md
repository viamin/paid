---
parent: PAID
prefix: LID-DETECTION
---

# Low-Level Design: Project LID Detection

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers how Paid detects whether a downstream repository is configured
> for Linked-Intent Development (LID), stores only the effective mode plus
> detection metadata, and lets project owners override or re-run detection.

## Purpose

Paid needs a fast, repo-authoritative answer to one question before later LID
features can branch prompt or run behavior: is this downstream project a LID
project, and if so in which mode?

The repository remains the source of truth. Paid stores only:

- the effective `projects.lid_mode` (`nil`, `"full"`, or `"scoped"`)
- detection metadata in `projects.lid_detection`

Paid does not copy the design tree into its own schema.

## Detection inputs

Detection reads the checked-out repository in this order:

1. The repo instruction file (`AGENTS.md`, falling back to `CLAUDE.md`) for a
   `## LID` section.
2. LID-shaped artifacts:
   `docs/intent/` content, `docs/high-level-design.md`,
   `docs/arrows/index.yaml`.

If a `## LID` block is present but `- Mode:` is missing or malformed, detection
defaults to Full mode and records a warning. Version is read from `- Version:`
when present.

If the project declares Scoped mode but omits `## LID Scope`, detection keeps
the project in Scoped mode, records a warning, and treats future scope checks
as in-scope-by-default until a scope section is added.

If a `## LID` block declares a mode but the repository has neither
`docs/high-level-design.md` nor any `docs/intent/` content, detection records
a warning rather than silently proceeding. The warning is advisory: it is
surfaced in the project settings UI so owners know standard design docs are
absent. Downstream contract injection uses resilient, path-agnostic wording
unconditionally, so agents do not waste tokens searching for design artifacts
the repo never populated.

## Persistence model

Detection writes:

- `projects.lid_mode` as the currently effective mode (skipped when a manual
  override is in effect and detection is not an explicit re-detect)
- `projects.lid_mode_overridden` as whether the owner has manually forced the
  mode from settings
- `projects.lid_detection` as metadata with the detected version, timestamp,
  source signals, and warnings

The metadata is diagnostic and explanatory; it is not a second source of truth.

## Lifecycle hooks

Detection runs anywhere Paid already scans repository conventions from a local
checkout:

- repo import
- normal collector syncs

Using the existing project-conventions collector keeps instruction-file reads in
one repo-scan path instead of duplicating them.

## Override model

Project owners can:

- force LID off (`nil`)
- force Full mode
- force Scoped mode
- re-run repo detection

The override is applied through project settings by writing `projects.lid_mode`
directly, which also sets `projects.lid_mode_overridden`. Re-detect replaces
that value with the repo-derived result, refreshes `projects.lid_detection`,
and clears `lid_mode_overridden`.

Background detection (repo import, normal collector sync) always refreshes
`projects.lid_detection` metadata, but skips writing `projects.lid_mode` while
`lid_mode_overridden` is true — otherwise a routine sync would silently discard
the owner's override. Detection during an explicit re-detect always applies,
regardless of the override flag.
