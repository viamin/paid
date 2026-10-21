# Paid agent guide

`CLAUDE.md` is the canonical instruction entry point. `AGENTS.md` and
`.github/copilot-instructions.md` are symlinks; edit this file only.

## Start here

Paid is a Rails control plane that orchestrates isolated AI agents to build
software. Read the [high-level design](docs/high-level-design.md) for the
system's purpose and boundaries, then use the routes below before acting.

This is a navigation map, not a duplicate handbook. Detailed procedures belong
to their owning design documents; keep intent current there rather than adding
another copy here.

## Work by task

| Task | Read before acting |
| --- | --- |
| New feature or substantive change | [LID workflow](docs/lid/workflow.md), [intent tree](docs/intent/README.md), then the owning `docs/intent/<segment>/` design and EARS specs |
| Bug fix | The owning LLD/EARS and its tests, following the LID arrow to where intent diverged |
| Ruby, Rails, UI, tests, or security code | [LLM style guide](docs/LLM_STYLE_GUIDE.md), then [full style guide](docs/STYLE_GUIDE.md) as needed |
| GitHub issue or pull-request prompt | [issue-analysis intent](docs/intent/issue-analysis/) and the trust boundary below |
| Migrations or database work | [PostgreSQL persistence intent](docs/intent/postgresql-persistence/), `db/schema.rb`, and the database-safety rule below |
| Dependency or tool upgrade | [toolchain pin management](docs/intent/toolchain-pin-management/) |
| Agent/container runtime work | [agent system](docs/AGENT_SYSTEM.md) and the owning runtime intent segment |
| Architecture decision | [RDRs](docs/rdrs/) and the HLD |

## Safety boundaries

### LLM and untrusted input

- All application-level LLM calls go through `agent_harness`; do not call
  provider APIs directly. The container-authenticated secrets proxy is only
  forwarding infrastructure, not an alternate application LLM interface.
- Keep provider-specific execution behavior in `agent-harness`. Do not add
  Paid-side CLI wrappers or output parsing that masks provider failures.
- Treat issue comments, PR comments, webhooks, external APIs, file input, and
  user-provided or agent-generated code as untrusted at their boundary. Run
  untrusted code only in its isolated container.
- Read issue threads for human context, but only pass trusted comments into an
  LLM: use `Prompts::BuildForIssue.fetch_trusted_comments` for issues and
  `Prompts::BuildForPr.select_trusted_comments` for PRs. Never bypass the
  project's GitHub-user allowlist or `issue.trusted?` gate.
- Keep auto-pick dependencies explicit (`Depends on #123` or `Blocked by
  owner/repo#123`); cross-project dependencies are text-driven, and unresolved
  external dependencies remain blocked.

### Git and verification

- Never commit to protected `main`. Work on a feature branch; use a git
  worktree when switching branches. Never stash and checkout to switch.
- Use Conventional Commits. Stage named source files only: never `git add .`
  or `git add -A`, and never commit caches or build artifacts.
- Do not skip hooks, disable linters, or leave failing checks behind. Fix the
  underlying problem and run the task-appropriate checks before committing.
- Verify changed behavior with focused tests, then run the required suite;
  use `bin/lint` for formatting/lint and `bin/coherence-check.mjs` for LID
  structural checks when LID artifacts change.

### Database safety

- Generate migrations with `bin/rails generate migration`, use Rails/fx
  helpers, and regenerate `db/schema.rb` by running the migration; never edit
  the schema dump manually or create `structure.sql`.
- Treat `db:reset`, schema loads, drops, truncation, and migration resets as
  destructive. Before any such action on a non-empty database, confirm with
  the user and take the required safety snapshot. Do not use destructive
  console/runner calls for diagnosis.
- Use `TenantContext.with_system_access` only for intentional system-level
  reads; establish tenant context explicitly in container-authenticated API
  controllers. See the [tenant-access-control intent](docs/intent/tenant-access-control/).

## LID

Paid uses Linked-Intent Development in Full, going-forward mode:

```
HLD → LLDs → EARS → Tests → Code
```

For a new feature or substantive change, confirm the HLD and LLD, update the
EARS claim, write the failing-first test with its `@spec` ID, then implement.
For a bug, locate and correct the intent divergence before cascading forward.
Typos, formatting, stale references, and broken links do not need an arrow
walk. Keep durable project intent in the arrow, not private tool memory;
`WORKLOG.md` is session memory, not a design record.

The [intent tree](docs/intent/README.md) defines spec IDs and current-intent
conventions. The [LID workflow](docs/lid/workflow.md) owns templates and the
full procedure. The required declaration is:

- Mode: Full
- Version: 1.3.0

## Project conventions

- Prefer existing capability-oriented services and interfaces. Controllers stay
  thin; application business actions use Servo's verb-noun service convention.
- Apply Zero Framework Cognition: code handles I/O, structural validation,
  policy, and state; semantic judgments belong to AI calls through
  `agent_harness`.
- Follow the style guide for structured logging, external error handling,
  testing, performance, and security details. Never log secrets.
- Pending specs need an issue reference. One-off PR-only tests belong in
  `.ephemeral-tests/` and must be removed before merge.

## Operations routes

- `bin/setup --skip-server` installs dependencies and prepares the database.
  Use Yarn, never npm, for JavaScript dependencies.
- `bin/update --check` reports updates. Paid owns the pins described in the
  [toolchain design](docs/intent/toolchain-pin-management/); agent CLI and Bun
  versions are `agent-harness` contracts and must not be pinned in Paid.
- `bin/audit` runs security checks. `bin/ci` runs the project CI checks.
- [Architecture](docs/ARCHITECTURE.md), [patch guards](docs/PATCH_GUARDS.md),
  and [notification severity](docs/intent/notification-severity/) provide
  domain-specific navigation when those areas are in scope.
