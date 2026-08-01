# `docs/lid/` — LID Method Reference

This directory is a **vendored reference library** for the Linked-Intent
Development (LID) *method*. It is distinct from `docs/intent/`, which holds
**Paid's own** design tree (its HLD, LLDs, and EARS specs). Nothing here is a
Paid EARS claim or design doc — these files describe *how to do LID*, not what
Paid is.

## Why this exists

LID is enforced richly in **Claude Code** (and Cursor) via the `jszmajda/lid`
plugin, whose `SKILL.md` skills auto-invoke the six-phase workflow on any code
change. Tools that are **not** plugin hosts — Codex, Gemini CLI, OpenCode, and
others used in this repo — read only `CLAUDE.md`/`AGENTS.md`. That instruction
file carries the LID *policy* (the arrow, the conventions), but not the
*procedure* (the six phases with their mandatory stops, the intent-narrowing
edge audit, the templates, the coherence checks).

`docs/lid/` vendors the procedure so every tool working on Paid gets the same
workflow Claude Code gets automatically. It also matters beyond Paid's own
development: Paid orchestrates agents that work *on* downstream projects, some
of which are themselves LID projects, so the canonical procedure belongs
in-repo as a reference.

## Contents

| File | What it is | Source |
|---|---|---|
| `workflow.md` | The six-phase LID workflow + cascade/coherence rules | adapted from `linked-intent-dev/SKILL.md` |
| `hld-template.md` | HLD standard sections | vendored verbatim |
| `lld-templates.md` | LLD structure template | vendored verbatim |
| `ears-syntax.md` | EARS syntax, spec-ID format, scope disambiguation | vendored verbatim |
| `decision-doc-template.md` | Decision-doc structure + earns-its-place heuristic | vendored verbatim |
| `audit-checklist.md` | The five coherence/audit checks | vendored verbatim |
| `incremental-tagging.md` | Brownfield `@spec` maturation policy | Paid-specific |

The runnable coherence check is `bin/coherence-check.mjs` (a vendored +
Rails-adapted reference implementation — adds `*.rb` to the scan and `vendor`,
`tmp`, `.bundle`, `storage` to the excludes, plus `--color=never` to keep ANSI
escapes out of the line parser), declared in `CLAUDE.md` under `## LID Tooling`.

## How to use it (non-Claude tools)

1. Read `workflow.md` start-to-finish once — it is the procedure Claude Code
   runs automatically.
2. On any code change, walk the arrow: HLD check → LLD → EARS → intent-narrowing
   edge audit → tests-first → code, stopping for review at each phase boundary.
3. Use the templates (`hld-template.md`, `lld-templates.md`, `ears-syntax.md`,
   `decision-doc-template.md`) when authoring or revising the design tree under
   `docs/intent/`.
4. Run `bin/coherence-check.mjs` for the structural checks in
   `workflow.md` § Coherence verification.
5. Use `incremental-tagging.md` for the default brownfield policy: mature
   `@spec` coverage as implementation runs touch each area; do not stage a
   mandatory repo-wide tagging sweep by default.

For the project-level *policy* (mode, conventions, navigation), see the
`## Linked-Intent Development (LID)` section of `CLAUDE.md` (canonical;
`AGENTS.md` is a symlink).

## Provenance & license

All files here originate from [`jszmajda/lid`](https://github.com/jszmajda/lid)
(MIT, © 2026 Jess Szmajda), pinned to plugin `linked-intent-dev` **v1.3.0** —
the version recorded in `CLAUDE.md` under `## LID`. The four `*-template.md` /
`*-syntax.md` / `audit-checklist.md` files are **byte-identical** to upstream
so a future sync is a plain `diff`. `workflow.md` is **adapted** (the
Claude-only frontmatter, auto-trigger framing, LID-on-LID section, and
plugin-internal path references were removed or rewritten for tool-agnostic
use); re-apply those adaptations after re-syncing.

## Sync policy

When bumping `- Version:` in the `## LID` block of `CLAUDE.md`:

1. `git clone https://github.com/jszmajda/lid` (or `git pull` an existing clone).
2. Re-copy the verbatim files from
   `plugins/linked-intent-dev/skills/linked-intent-dev/references/` and
   `plugins/arrow-maintenance/skills/arrow-maintenance/references/` over the
   matching files here — verify with `diff` that only intended upstream changes
   landed.
3. Re-derive `workflow.md` from
   `plugins/linked-intent-dev/skills/linked-intent-dev/SKILL.md`, re-applying
   the adaptations documented above.
4. Re-sync `bin/coherence-check.mjs` from
   `plugins/arrow-maintenance/skills/arrow-maintenance/references/coherence-check.mjs`
   and re-apply the Rails globs (`*.rb`; exclude `vendor`, `tmp`, `.bundle`,
   `storage`) and `--color=never`.
5. Update the version number in this README's "Provenance & license" section.

Do **not** edit the verbatim files locally — changes belong upstream. Local
adaptation is confined to `workflow.md`, `bin/coherence-check.mjs`, and this
README.
