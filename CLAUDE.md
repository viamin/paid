# CLAUDE.md

This file provides guidance to AI coding assistants when working with code in this repository.

> **Note**: `AGENTS.md` and `.github/copilot-instructions.md` are symlinks to this file.
> Edit only this file to keep all AI assistant instructions synchronized.

## Project Overview

Paid (Platform for AI Development) is a Rails 8 application that orchestrates AI agents to build software. It watches GitHub repos for labeled issues, plans implementations via LLM, and runs agents in isolated Docker containers to create pull requests.

**Status**: Planning phase - the codebase is a fresh Rails 8 scaffold with documentation. Implementation follows the documented architecture in `docs/`.

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
bin/lint                     # Run all linters (RuboCop, markdownlint)
bin/lint -A                  # Run all linters with auto-fix
bin/rubocop                  # Run RuboCop (rubocop-rails-omakase style)
bin/rubocop -a               # Auto-fix violations

# Security
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

## Architecture

The system has four main layers:

1. **Rails Application** - Control plane with Hotwire UI, PostgreSQL, GoodJob background jobs
2. **Temporal Orchestration** - Durable workflows for agent execution (to be implemented)
3. **Container Management** - Docker containers with git worktrees for isolated agent execution
4. **Agent Layer** - agent-harness gem providing unified interface to CLI agents (Claude Code, Cursor, etc.)

Key architectural decisions are documented in `docs/rdrs/` (Recommendation Decision Records).

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

### Zero Framework Cognition (ZFC)

Orchestration code should be mechanically simple - delegate all semantic reasoning to AI:

- **Keep in code**: I/O, structural safety checks, policy enforcement, state management
- **Delegate to AI**: Quality judgments, semantic analysis, plan composition, pattern matching for meaning

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

## Key Documentation

- `docs/ARCHITECTURE.md` - System design and technology stack
- `docs/AGENT_SYSTEM.md` - Temporal workflows and container management
- `docs/STYLE_GUIDE.md` - Detailed coding standards and patterns
- `docs/DATA_MODEL.md` - Database schema and RBAC
- `docs/rdrs/` - All architectural decision records
