# `docs/arrows/` — Arrow of Intent Tracking

This directory tracks the arrow of intent across the project — the chain from
high-level design through to realized code:

```
HLD → LLDs → EARS → Tests → Code
```

## Files

- **`index.yaml`** — the dependency graph. Load it first to understand what's
  available, what's blocked, and what needs work. The status enum and field
  reference live in the
  [upstream schema](https://github.com/jszmajda/lid/blob/main/plugins/arrow-maintenance/skills/arrow-maintenance/references/index-schema.md).
- **`{segment-name}.md`** — one orientation page per arrow segment
  (References, Spec Coverage, Key Findings), created as segments are mapped.

## Status

Empty — nothing mapped yet. Paid adopts LID going-forward (Full mode,
brownfield), so this overlay grows as arrow segments are created under
`docs/intent/`. See `docs/intent/README.md` for when to add a segment and the
root `AGENTS.md` for the full workflow.
