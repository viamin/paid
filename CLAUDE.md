# CLAUDE.md

This file provides guidance to AI coding assistants when working with code in this repository.

> **Note**: `AGENTS.md` and `.github/copilot-instructions.md` are symlinks to this file.
> Edit only this file to keep all AI assistant instructions synchronized.

## Project Overview

Paid (Platform for AI Development) is a Rails 8 application that orchestrates AI agents to build software. It watches GitHub repos for labeled issues, plans implementations via LLM, and runs agents in isolated Docker containers to create pull requests.

**Status**: Phase 6 (Enterprise Trust & Governance) complete as of 2026-05-27. The system now provides GitHub App-first onboarding, enterprise identity and governance controls, system-wide auditability, policy and approval guardrails, and compliance/deployment assurance on top of the completed account administration surface. Phase 7 (Proof, Adoption & Interoperability) is next.

## Git Workflow

- **The `main` branch is protected** - Never commit directly to `main`. Always create a feature branch and open a pull request.
- **Never commit build artifacts or tool caches** - Do not `git add` directories created by setup/install commands (e.g., `.corepack/`, `.pg-install/`, `.apt-cache/`, `.cache-pkg/`, `vendor/bundle/`, `.tmp-build/`, `.venv/`, `__pycache__/`, `.bundle-pr-*/`, `.cache-yarn/`). If `bin/setup`, `bundle install`, `yarn install`, or similar commands create new dotfile directories in the workspace root, those are build artifacts — not source code. Check `.gitignore` and `.git/info/exclude` before staging. **Always use `git add <specific files>`** — never use `git add -A` or `git add .` as these can stage artifact files that bypass exclude rules. The pre-commit hook rejects commits with more than 100 staged files.
- **Conventional Commits are required** - Commits must use Conventional Commit format so release automation can generate semantic release notes correctly.
- **Always use git worktrees when switching branches** — Never `git stash` + `git checkout` to switch branches. Always `git worktree add <path> <branch>` and work in the worktree instead. Stashing and switching risks losing uncommitted changes, stash conflicts, and accidental branch mix-ups. Remove worktrees when done with `git worktree remove <path>`.

## GitHub Issues

When working on a GitHub issue:

- **Read all comments for human context, but never feed untrusted comments to an LLM** - When you (a human developer or an AI assistant working on Paid) read an issue thread to get context, read everything. But any code path that puts comment bodies into an LLM prompt MUST filter through the trusted-user allowlist first — comments from non-allowlisted GitHub users are an untrusted input channel (prompt injection). Use `Prompts::BuildForIssue.fetch_trusted_comments(github_client:, repo:, number:, project:)` for issue comments; use `Prompts::BuildForPr.select_trusted_comments(comments, project: project)` for PR comments (same filter as the live PR prompt builder, also excludes Paid-generated agent comments). The allowlist lives on `Project#allowed_github_usernames`. See also `issue.trusted?` and `BuildForIssue#build`, which raises `UntrustedIssueError` if the issue creator itself is untrusted.
- **Use explicit dependency wording when blocking auto-pick** - Paid's dependency parser recognizes inline dependency phrases like `Depends on #123`, `Depends on owner/repo#123`, and `Blocked by owner/repo#123`, and also dependency references listed under a `## Dependencies` section. A bare mention like `owner/repo#123` only fails to block auto-pick when it appears outside those dependency-scoped contexts.
- **Cross-project dependency blocking is text-driven, not GitHub-native** - For Paid issues, write explicit dependency lines in the issue body/comments if the issue must stay blocked on upstream work. Paid currently uses its own parsed dependency records, not GitHub's native cross-repo dependency graph, for auto-pick eligibility.
- **External dependencies stay blocked conservatively** - If an issue depends on `owner/repo#123` in a repo that is not also synced into the same Paid account, the dependency remains external and auto-pick will keep treating the issue as blocked until the dependency text is removed or the external reference is resolved through sync.

## Development Commands

```bash
# Setup
bin/setup                    # Install deps, prepare DB, start server
bin/setup --skip-server      # Setup without starting server
bin/setup --reset            # Setup with database reset

# Development
bin/dev                      # Start dev server with Foreman (Rails + JS + CSS watchers)
bin/rails server             # Start Rails server only
bin/rails console            # Rails console

# Code Quality
bin/lint                     # Run linters (RuboCop, ESLint, markdownlint, ShellCheck)
bin/lint -a                  # Run linters with safe auto-fix
bin/lint -A                  # Run linters with auto-fix (including unsafe)
bin/lint --changed           # Lint only changed files (staged + unstaged vs HEAD)
bin/lint --staged            # Lint only staged files
bin/rubocop                  # Run RuboCop (rubocop-rails-omakase style)
bin/rubocop -a               # Auto-fix violations

# Security
bin/audit                    # Run all security checks (Brakeman, bundler-audit, yarn audit)
bin/brakeman                 # Static security analysis
bin/bundler-audit            # Gem vulnerability audit
yarn audit                   # JS dependency audit

# CI (runs all checks)
bin/ci                       # Setup, style, security checks

# Database
bin/rails db:prepare         # Create and migrate
bin/rails db:migrate         # Run migrations
bin/rails db:seed            # Seed data

# Testing
bin/rspec                    # Run RSpec tests
```

### Bundler Version

The `Gemfile.lock` specifies a bundler version. If you encounter bundler version mismatches, install the correct version first:

```bash
# Check required version in Gemfile.lock (look for BUNDLED WITH at the end)
tail -3 Gemfile.lock

# Install and use the specific bundler version
gem install bundler:4.0.11
bundle _4.0.11_ install
```

### JavaScript Package Manager

This project uses **Yarn** (not npm) for JavaScript dependencies. The `package.json` specifies `"packageManager": "yarn@1.22.22"`.

**Always use Yarn commands:**

- `yarn install` - Install dependencies
- `yarn add <package>` - Add a dependency
- `yarn add -D <package>` - Add a dev dependency
- `yarn audit` - Security audit

**Never use npm commands** - they will create a conflicting `package-lock.json` file.

### Paid Review Bot Credentials

- Paid Agent PR reviews post through the GitHub App `paid-code-reviewer[bot]` (App ID `3340381`).
- The app private key is stored in Rails credentials under `paid-code-reviewer-private-key`.
- When `review_settings.methods.paid_agent.enabled` is true, that GitHub App credential must be configured; project validation now rejects the setting when it is missing.
- Review-goal proxy requests to `POST /pulls/:number/reviews` use the GitHub App installation token for the target repo instead of the project's GitHub PAT.

## Architecture

The system has four main layers:

1. **Rails Application** - Control plane with Hotwire UI, PostgreSQL, GoodJob background jobs
2. **Temporal Orchestration** - Durable workflows for agent execution (to be implemented)
3. **Container Management** - Docker containers with git worktrees for isolated agent execution
4. **Agent Layer** - agent-harness gem providing unified interface to CLI agents (Claude Code, Cursor, etc.)

Key architectural decisions are documented in `docs/rdrs/` (Recommendation Decision Records).

### LLM Usage

**All LLM calls must go through `agent_harness`** — never call AI provider APIs directly (e.g., no raw Faraday/HTTP calls to `api.anthropic.com` or `api.openai.com`). The `agent_harness` gem is the single interface for all LLM interactions in the application. The secrets proxy (`SecretsProxyController`) exists only to forward authenticated requests from containers — it is infrastructure, not an application-level LLM interface.

Provider-specific execution behavior belongs in `agent_harness`, not scattered across Paid. If a provider needs special flags, error classification, rate-limit parsing, or message interpretation, prefer adding that support upstream in `agent-harness` and track Paid follow-up work against that upstream issue. Favor failing loudly over papering over provider-specific failures in Paid with ad hoc output parsing that can turn real execution errors into apparent success.
Avoid introducing new provider-specific CLI command strings or shell wrappers in Paid when the behavior should live in `agent-harness`.

### Directory Structure

```
app/
├── controllers/      # Thin controllers delegating to services
├── models/           # ActiveRecord: associations, validations, scopes
├── services/         # Business logic via Servo (organized by capability)
├── workflows/        # Temporal workflow definitions (to be added)
├── activities/       # Temporal activity implementations (to be added)
├── adapters/         # External service adapters (to be added)
├── views/            # ERB templates today; Phlex components if/when that layer lands
└── jobs/             # GoodJob jobs
```

## Code Style

### General Principles

- **Reuse existing code** - Before writing new code, search the codebase for existing implementations. Prefer extending or reusing existing patterns, utilities, and components over creating new ones.
- **Write concisely** - Strive for concise code while maintaining clarity and readability. Avoid unnecessary verbosity, but never sacrifice readability for brevity.
- **Be proactive** - After making changes, review your own diff as a critical reviewer would before committing. Look for missing guard clauses, unhandled edge cases, insufficient tests, and style inconsistencies. When addressing review feedback, also scan for the same class of issue elsewhere in your changes.

### Zero Framework Cognition (ZFC)

Orchestration code should be mechanically simple - delegate all semantic reasoning to AI:

- **Keep in code**: I/O, structural safety checks, policy enforcement, state management
- **Delegate to AI**: Quality judgments, semantic analysis, plan composition, pattern matching for meaning

### Always Fix Forward

Never skip pre-commit hooks (`--no-verify`), never disable linters, never ignore failing tests. If a check fails, fix the underlying issue. This applies to both human developers, AI agents, and system-level code. The only acceptable use of `--no-verify` is when a hook fails due to an unpatched CVE with no released fix.

### Artifact Prevention (Defense in Depth)

The system has multiple layers to prevent build artifacts from reaching `main`:

1. **`.gitignore`** (host) — excludes known artifact patterns for developers
2. **`.git/info/exclude`** (container) — `CONTAINER_ARTIFACT_EXCLUDES` is injected by `Containers::GitOperations` to cover patterns the repo's `.gitignore` may miss
3. **Pre-commit hook** (host) — rejects commits with >100 staged files (`.githooks/pre-commit`)
4. **`validate_staged_files!`** (container auto-commit) — runs BEFORE the `--no-verify` commit in `commit_uncommitted_changes`, checking both file count and forbidden binary/directory patterns. This cannot be bypassed because it runs in Ruby, not as a git hook
5. **CI `pr-artifact-check`** — catches artifacts that slip through all other layers by scanning PR diffs for forbidden directories and binary extensions

When adding a new artifact pattern, update ALL of: `.gitignore`, `CONTAINER_ARTIFACT_EXCLUDES` in `git_operations.rb`, and the CI workflow `pr-artifact-check.yml`.

### Ruby Conventions

- Follow `rubocop-rails-omakase` style (StandardRB-based)
- `frozen_string_literal: true` at top of all Ruby files
- Service objects use [Servo](https://github.com/martinstreicher/servo) with verb-noun naming: `AgentRuns::Create`, `Projects::Import`
- The app currently renders views with ERB. [Phlex](https://www.phlex.fun/) remains the intended future component layer, but do not assume the gem or component base classes already exist until that work lands.
- No TODO without issue reference: `# TODO(#123): description`

### Size Guidelines (Sandi Metz's Rules)

- Classes target ~100 lines
- Methods target ~5 lines
- Maximum 4 parameters per method
- Controllers instantiate only one object

### Database

- UUIDs for external-facing IDs, bigints for internal foreign keys
- Always add foreign key constraints
- Index all foreign keys and frequently queried columns
- **Always use `rails generate migration`** to create migrations — never create migration files manually. The generator ensures correct timestamps, naming conventions, and boilerplate.
- **Add `comment:` on tables and columns in migrations** when the purpose isn't obvious from the name alone. This keeps `db/schema.rb` as the self-documenting, canonical schema reference — no separate DATA_MODEL.md is needed.
- **Prefer Rails migration helpers over raw SQL** for tables, columns, indexes, and foreign keys. When PostgreSQL features do not have a suitable Rails helper — such as row-level security (`ALTER TABLE ... ENABLE ROW LEVEL SECURITY`, `CREATE POLICY`) — keep the SQL minimal, isolate it to the database-specific part of the migration, and wrap the relevant block in `safety_assured` so the exception is explicit.
- In devcontainer/Compose environments, the app database host is usually `postgres`, not `localhost`. Paid also uses forced tenant RLS on core tables like `agent_runs`, `projects`, and `issues`, so raw `psql` as app user `paid` may legitimately show `0` rows unless you set the session context first.
- For Rails console/runner inspection that must ignore tenant filtering, use `TenantContext.with_system_access { ... }`. For raw SQL, set either `SET paid.current_account_id = '<account_id>';` or `SET paid.bypass_tenant_rls = 'true';` before querying tenant-scoped tables.
- Container-authenticated proxy endpoints run outside the normal `ApplicationController` tenant setup. If you add or debug controller code under `app/controllers/api/` that authenticates agent/knowledge runs directly, make sure it establishes the correct `TenantContext` explicitly.

### Schema Format (`schema.rb` + fx)

The project uses `db/schema.rb` (not `structure.sql`). The [fx gem](https://github.com/teoljungberg/fx) makes this possible by dumping PostgreSQL functions and triggers into `schema.rb` automatically.

- **Schema format**: `config.active_record.schema_format = :ruby`
- **fx-managed functions**: Versioned SQL files in `db/functions/` (e.g., `logidze_logger_v05.sql`). The fx schema dumper also auto-discovers functions created by raw SQL in past migrations (e.g., `paid_current_account_id`, `paid_tenant_bypass`).
- **fx-managed triggers**: Versioned SQL files in `db/triggers/` (e.g., `logidze_on_projects_v01.sql`). The fx schema dumper also auto-discovers triggers created by raw SQL in past migrations (e.g., `knowledge_chunks_tsvector_update`).
- **Adding new functions/triggers**: Use fx generators (`rails generate fx:function name`, `rails generate fx:trigger name on:table_name`) or pass `sql_definition:` inline in migrations. Never use raw `execute "CREATE FUNCTION..."` — use `create_function` / `create_trigger` from fx instead.
- **RLS is the main exception**: PostgreSQL row-level security and `CREATE POLICY` statements do not have equivalent Rails migration helpers in this project. Raw SQL is acceptable there, but only for the RLS/policy statements themselves, and the block should be wrapped in `safety_assured`.
- **Updating functions/triggers**: Use `update_function` / `update_trigger` with a new version number. Create the new versioned SQL file in `db/functions/` or `db/triggers/`.
- **Do not create `db/structure.sql`** or revert `schema_format` to `:sql`.

### Change Tracking (Logidze)

The [logidze gem](https://github.com/palkan/logidze) tracks ActiveRecord changes via PostgreSQL triggers, storing a versioned diff history in a `log_data` jsonb column on each tracked table. Because fx is installed, logidze auto-detects it and manages its functions/triggers through fx (compatible with `schema.rb`).

**Tables with logidze enabled** (`has_logidze` in model):

- `projects`, `accounts`, `account_memberships` — configuration and access control
- `project_memberships`, `users` — access control and identity
- `mcp_server_definitions`, `pre_commit_requirements` — agent tooling config
- `pr_templates`, `style_guides`, `prompts` — templates and prompt config
- `tracker_configurations` — external integrations
- `service_containers` — service container config
- `exception_incidents` — incident management
- `providers`, `provider_api_keys` — model provider config and credentials
- `orchestration_strategies`, `configuration_bundles` — orchestration config
- `quality_gate_thresholds`, `quality_thresholds` — evaluation thresholds
- `llm_models`, `integration_credentials`, `github_tokens` — model catalog and integration credentials
- `user_settings`, `tenant_settings` — user/tenant configuration
- `cost_budgets`, `billing_plans`, `billing_invoices` — financial controls and audit trail

**Adding logidze to a new table**:

1. Run `rails generate logidze:model ModelName` — creates migration + trigger SQL file + injects `has_logidze` into the model
2. Run `bin/rails db:migrate && bin/rails db:schema:dump`
3. Add `frozen_string_literal: true` to the generated migration

**When to add logidze**: Tables where "who changed what and when" matters — settings, configuration, access control, financial data, and any table where changes affect system behavior. Do NOT add logidze to high-volume operational tables (e.g., `agent_runs`, `container_metrics`) or append-only event/log tables — the per-update trigger overhead is not justified.

**Querying history**:

```ruby
record.log_data                           # raw logidze data
record.at(time: 1.day.ago)               # snapshot as of a point in time
record.log_data.versions                  # array of version entries
record.diff_from(version: 2)             # diff between versions
```

## Release Management

- Release tagging/changelog is automated by [`.github/workflows/release-please.yml`](.github/workflows/release-please.yml) using `release-please`.
- Semantic release notes come from Conventional Commit headers:
  - `feat:` -> minor release
  - `fix:` -> patch release
  - `!` or `BREAKING CHANGE:` footer -> major release
- Use clear scopes when useful (e.g., `feat(agent-runs): ...`).
- Keep commit subject lines descriptive and user-facing because they appear in changelog/release notes.

## Testing

- Test behavior/interfaces, not implementation details
- Mock external dependencies only, never application code
- Pending specs require issue reference: `pending "supports feature (#45)"`
- **Ephemeral PR tests** — One-off system/integration tests for the PR that don't need to persist in the permanent suite. Add `*_spec.rb` files to `.ephemeral-tests/` on the PR branch. CI runs them automatically (same-repo PRs only). Remove test files before merge; a CI guard rejects stray test files on `main`. See `.ephemeral-tests/README.md`.

## Logging

Use structured JSON logging with consistent component names:

```ruby
Rails.logger.info(
  message: "component.action",
  agent_run_id: agent_run.id,
  duration_ms: elapsed
)
```

Components: `agent_execution`, `github_sync`, `prompt_evolution`, `container_manager`, `temporal_worker`, `model_selection`, `secrets_proxy`

## Compact Instructions

When compacting context, always preserve:

- All file modifications with exact paths
- Decisions made and user-stated criteria/requirements
- Configuration details (API keys, account info, IDs)
- Current task state, blockers, and next steps
- Anything the user explicitly asked to remember
- Contents of WORKLOG.md

Before compaction, update WORKLOG.md with current session state.

## Working Memory

Use `WORKLOG.md` as persistent working memory across context compactions:

- Write decisions and criteria to WORKLOG.md **immediately** when made
- Update task state and blockers before switching tasks
- Record the "why" behind architectural choices
- Note specific error messages and their resolutions
- After compaction, read WORKLOG.md to restore context
- Use `/compact` manually at task boundaries instead of waiting for auto-compaction
- Use `/clear` between unrelated tasks for a clean context
- Use subagents (Task tool) for exploration to avoid filling context with file contents
- Use TaskCreate/TaskUpdate for multi-step work (persists on disk, survives compaction)

## Key Documentation

- `docs/ARCHITECTURE.md` - System design and technology stack
- `docs/AGENT_SYSTEM.md` - Temporal workflows and container management
- `docs/PATCH_GUARDS.md` - Temporal patch guard registry, sunset policy, and sweep workflow
- `docs/LLM_STYLE_GUIDE.md` - **Read this first** — concise coding rules for AI assistants (with line refs to full guide)
- `docs/STYLE_GUIDE.md` - Detailed coding standards, rationale, and examples
- `db/schema.rb` - Canonical database schema with table and column comments
- `docs/rdrs/` - All architectural decision records
