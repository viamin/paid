---
parent: PAID
prefix: AGENT-INSTRUCTION
---

# Low-Level Design: Agent Instruction Navigation

## Purpose

`CLAUDE.md` is the canonical, always-loaded instruction entry point for Paid;
`AGENTS.md` and `.github/copilot-instructions.md` are symlinks to it. It must
make universal constraints visible without duplicating the detailed procedures
that already own project intent.

## Navigation contract

The entry point keeps the LID arrow, trust and LLM boundaries, Git/worktree and
verification constraints, database-safety rule, and dependency ownership
visible. It links to the HLD, LID workflow, style guides, and relevant intent
segments before an agent needs their detailed procedures. Detailed procedures
remain in those owners, not in another instruction handbook.

## Structural verification

`scripts/check_instruction_links.mjs` validates the canonical entry point,
both symlinks, required task-routing headings, required navigation targets,
and every local Markdown link in `CLAUDE.md`. `bin/lint` runs it so a moved or
renamed destination cannot silently strand a cold-start workflow.
