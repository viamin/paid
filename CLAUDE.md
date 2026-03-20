# CLAUDE.md

This file provides guidance to AI coding assistants when working with code in this repository.

> **Note**: `AGENTS.md` and `.github/copilot-instructions.md` are symlinks to this file.
> Edit only this file to keep all AI assistant instructions synchronized.

## Project Overview

Paid (Platform for AI Development) is a Rails 8 application that orchestrates AI agents to build software. It watches GitHub repos for labeled issues, plans implementations via LLM, and runs agents in isolated Docker containers to create pull requests.

**Status**: Phase 1 (Foundation) complete. The MVP is working end-to-end: users can add GitHub projects, label issues, and agents create PRs in isolated Docker containers. Phase 2 (Intelligence) is next.

## Git Workflow

- **The `main` branch is protected** - Never commit directly to `main`. Always create a feature branch and open a pull request.
- **Never commit build artifacts or tool caches** - Do not `git add` directories created by setup/install commands (e.g., `.corepack/`, `.pg-install/`, `.apt-cache/`, `.cache-pkg/`, `vendor/bundle/`, `.tmp-build/`, `.venv/`, `__pycache__/`). If `bin/setup`, `bundle install`, `yarn install`, or similar commands create new dotfile directories in the workspace root, those are build artifacts — not source code. Check `.gitignore` and `.git/info/exclude` before staging. When in doubt, use `git add <specific files>` rather than `git add -A`.
- **Conventional Commits are required** - Commits must use Conventional Commit format so release automation can generate semantic release notes correctly.
- **Use git worktrees for concurrent branch work** - When working on multiple branches (e.g., making a PR while another branch has uncommitted changes), use `git worktree add` instead of stashing and switching branches. This avoids lost edits, stash conflicts, and accidental branch mix-ups. Remove worktrees when done with `git worktree remove`.

## GitHub Issues

When working on a GitHub issue:

- **Read all comments** - Always read the entire comment thread on an issue before starting work. Important context, clarifications, and decisions are often in the comments.

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
gem install bundler:2.7.2
bundle _2.7.2_ install
```

### JavaScript Package Manager

This project uses **Yarn** (not npm) for JavaScript dependencies. The `package.json` specifies `"packageManager": "yarn@1.22.22"`.

**Always use Yarn commands:**

- `yarn install` - Install dependencies
- `yarn add <package>` - Add a dependency
- `yarn add -D <package>` - Add a dev dependency
- `yarn audit` - Security audit

**Never use npm commands** - they will create a conflicting `package-lock.json` file.

## Architecture

The system has four main layers:

1. **Rails Application** - Control plane with Hotwire UI, PostgreSQL, GoodJob background jobs
2. **Temporal Orchestration** - Durable workflows for agent execution (to be implemented)
3. **Container Management** - Docker containers with git worktrees for isolated agent execution
4. **Agent Layer** - agent-harness gem providing unified interface to CLI agents (Claude Code, Cursor, etc.)

Key architectural decisions are documented in `docs/rdrs/` (Recommendation Decision Records).

### LLM Usage

**All LLM calls must go through `agent_harness`** — never call AI provider APIs directly (e.g., no raw Faraday/HTTP calls to `api.anthropic.com` or `api.openai.com`). The `agent_harness` gem is the single interface for all LLM interactions in the application. The secrets proxy (`SecretsProxyController`) exists only to forward authenticated requests from containers — it is infrastructure, not an application-level LLM interface.

### Directory Structure

```
app/
├── controllers/      # Thin controllers delegating to services
├── models/           # ActiveRecord: associations, validations, scopes
├── services/         # Business logic via Servo (organized by capability)
├── workflows/        # Temporal workflow definitions (to be added)
├── activities/       # Temporal activity implementations (to be added)
├── adapters/         # External service adapters (to be added)
├── views/            # Phlex view components (to be added)
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

### Ruby Conventions

- Follow `rubocop-rails-omakase` style (StandardRB-based)
- `frozen_string_literal: true` at top of all Ruby files
- Service objects use [Servo](https://github.com/martinstreicher/servo) with verb-noun naming: `AgentRuns::Create`, `Projects::Import`
- Views use [Phlex](https://www.phlex.fun/) for pure Ruby components
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
- `docs/LLM_STYLE_GUIDE.md` - **Read this first** — concise coding rules for AI assistants (with line refs to full guide)
- `docs/STYLE_GUIDE.md` - Detailed coding standards, rationale, and examples
- `docs/DATA_MODEL.md` - Database schema and RBAC
- `docs/rdrs/` - All architectural decision records
