# EARS Specs: Agent Instruction Navigation

> Testable claims for the canonical AI-agent instruction entry point. Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **AGENT-INSTRUCTION-001** — The canonical `CLAUDE.md` SHALL expose the
  LID arrow, trust and LLM boundaries, Git/worktree and verification
  constraints, database-safety rule, and task-specific routes without
  duplicating the detailed procedures owned elsewhere.
  *Tests:* `test/scripts/check_instruction_links.test.mjs`.
  *Code:* `CLAUDE.md`.

- [x] **AGENT-INSTRUCTION-002** — When `bin/lint` runs, it SHALL reject a
  missing instruction entry point, broken instruction symlink, missing
  required route, or broken local link from `CLAUDE.md`.
  *Tests:* `test/scripts/check_instruction_links.test.mjs`.
  *Code:* `scripts/check_instruction_links.mjs`, `bin/lint`.
