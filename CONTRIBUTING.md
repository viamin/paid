# Contributing to Paid

Thank you for your interest in contributing to Paid.

Paid is a Rails 8 application that orchestrates AI agents to plan work, execute changes in isolated containers, and open pull requests. This guide covers the contributor workflow: how to get set up, how to make changes safely, and what to run before opening a PR.

For product overview and full local environment details, see [README.md](README.md). For architecture and coding conventions, start with:

- [docs/LLM_STYLE_GUIDE.md](docs/LLM_STYLE_GUIDE.md)
- [docs/STYLE_GUIDE.md](docs/STYLE_GUIDE.md)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/AGENT_SYSTEM.md](docs/AGENT_SYSTEM.md)
- [docs/DATA_MODEL.md](docs/DATA_MODEL.md)

## Before You Start

- Read the full issue thread before starting work. Important decisions often live in comments.
- Never commit directly to `main`. Create a feature branch and open a pull request.
- Use Yarn, not npm. The repo is pinned to `yarn@1.22.22`.
- Do not commit build artifacts or tool caches.
- All application-level LLM usage must go through `agent_harness`; do not add direct provider API calls in app code.

## Development Options

There are three supported ways to work on Paid:

1. Docker Compose
2. Dev Container / Codespaces
3. Local host development

### Option 1: Docker Compose

This is the easiest way to get the full stack running.

```bash
git clone <repo-url> && cd paid
cp .env.example .env
docker compose up --build
```

On first boot, wait for the `web` service to finish `bin/setup` before using the app.

By default, the checked-in Compose stack starts:

- PostgreSQL
- Temporal
- Temporal UI
- Temporal admin tools
- Qdrant
- the Rails web app
- the Temporal worker

The `agent-image` and `agent-test` services are profile-gated and do not start unless explicitly requested.

### Option 2: Dev Container / Codespaces

If you use VS Code Dev Containers or GitHub Codespaces, the repository includes a ready-to-use `.devcontainer/` setup.

If commit signing is not configured automatically in the container, run:

```bash
bash .devcontainer/enable-commit-signing.sh
```

### Option 3: Local Host Development

Prerequisites:

- Ruby 3.4+
- Bundler 2.7.2
- PostgreSQL 16+
- Node.js 22.x
- Yarn 1.22.22
- Docker Engine

If you use `asdf`, the repo pins tool versions in `.tool-versions`.

For local development, start PostgreSQL, Temporal, and Qdrant first, then run:

```bash
gem install bundler:2.7.2
bin/setup
bin/dev
```

`bin/setup` is the preferred setup path. It does more than install dependencies:

- configures git hooks
- installs Ruby and JavaScript dependencies
- prepares the database
- checks Qdrant connectivity
- builds the `paid-agent:latest` image
- cleans up stale local dev state

If Docker is unavailable, setup is incomplete.

## Environment Notes

`bin/dev` uses Overmind and starts the Rails server, JS watcher, CSS watcher, and Temporal worker together.

The default dev runner does not rely on automatic `.env` loading. Treat `.env.example` as a reference, and load required environment variables in your shell, dev container, or Compose configuration.

Common local endpoints:

- Rails app: <http://localhost:3000>
- Temporal UI: <http://localhost:8080>
- Qdrant: <http://localhost:6333>

## Daily Workflow

Create a feature branch from `main`:

```bash
git checkout -b fix/short-description
```

Make your changes, add or update tests, then run the relevant checks before you open a PR.

If you need to work on multiple branches at once, prefer `git worktree` instead of stashing and switching.

## Testing and Checks

Useful commands:

```bash
bin/rspec
bin/rubocop
bin/brakeman
bin/bundler-audit
bin/lint
bin/ci
```

Examples:

```bash
bin/rspec spec/models/project_spec.rb
bin/rspec spec/models/project_spec.rb:42
bin/lint --changed
bin/lint --staged
```

The test suite and tooling currently use:

- RSpec
- Factory Bot
- WebMock
- SimpleCov with an 80% minimum coverage target
- RuboCop (`rubocop-rails-omakase` + `rubocop-rspec`)
- ESLint
- markdownlint
- ShellCheck
- Brakeman
- bundler-audit

Before submitting a change, run the checks appropriate for your edits. In most cases, that means at least:

```bash
bin/rspec
bin/lint --changed
bin/brakeman
```

If you want the broader CI-style pass, run:

```bash
bin/ci
```

## Code Style

Paid follows `rubocop-rails-omakase` and the repo style guides. A few conventions matter especially often:

- Put `# frozen_string_literal: true` at the top of Ruby files.
- Prefer small classes and short methods.
- Keep controllers thin and push business logic into services.
- Service objects use [Servo](https://github.com/martinstreicher/servo) with verb-noun naming such as `AgentRuns::Create` or `Projects::Import`.
- Use structured JSON logging with consistent component names.
- Use Yarn commands for JavaScript dependencies.
- Use `rails generate migration` to create migrations; do not create migration files manually.
- Add foreign keys and indexes for new relational data.
- Never edit `db/schema.rb` directly.

When adding orchestration or automation code, keep the mechanics in code and delegate semantic judgment to AI systems where appropriate. See [docs/LLM_STYLE_GUIDE.md](docs/LLM_STYLE_GUIDE.md) for the project-specific rules.

## Commits

This repository enforces Conventional Commits through the local `commit-msg` git hook installed by `bin/setup`.

Examples:

```bash
git commit -m "feat: add prompt version comparison UI"
git commit -m "fix(agent-runs): persist provider error details"
git commit -m "docs: clarify docker compose setup"
```

Allowed commit types:

- `feat`
- `fix`
- `docs`
- `style`
- `refactor`
- `perf`
- `test`
- `build`
- `ci`
- `chore`
- `revert`

Use `!` or a `BREAKING CHANGE:` footer for breaking changes.

## Pull Requests

When opening a PR:

- keep it focused on one concern
- explain what changed and why
- link the related issue when applicable
- include tests for behavior changes
- make sure checks pass before requesting review

Please do not bypass hooks or disable failing checks. Fix forward instead.

## Architecture Pointers

Key directories you will work in most often:

```text
app/
├── controllers/           # Thin controllers
├── models/                # ActiveRecord models
├── services/              # Business logic and integrations
├── jobs/                  # GoodJob background jobs
├── temporal/
│   ├── workflows/         # Temporal workflow definitions
│   └── activities/        # Temporal activity implementations
├── policies/              # Pundit authorization policies
└── views/                 # ERB views with Hotwire
```

Helpful docs:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the system overview
- [docs/AGENT_SYSTEM.md](docs/AGENT_SYSTEM.md) for agent execution and Temporal
- [docs/DATA_MODEL.md](docs/DATA_MODEL.md) for schema and RBAC
- [docs/rdrs/](docs/rdrs/) for major design decisions
- [docs/ROADMAP.md](docs/ROADMAP.md) for planned work

## Getting Help

- Open an issue for bugs or feature requests.
- Review existing RDRs before proposing major architectural changes.
- If you are unsure whether a change belongs in Paid or upstream in `agent-harness`, ask early. Provider-specific execution behavior generally belongs upstream.
