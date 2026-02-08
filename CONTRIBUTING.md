# Contributing to Paid

Thank you for your interest in contributing to Paid! This guide covers development setup, code style, and how to submit changes.

## Development Setup

### Prerequisites

- Ruby 3.4+
- PostgreSQL 16+
- Node.js 20+ and Yarn
- Docker and Docker Compose (for Temporal and agent containers)

### Getting Started

```bash
# Clone the repository
git clone <repo-url> && cd paid

# Install Ruby dependencies
gem install bundler:2.7.2
bundle install

# Install JavaScript dependencies
yarn install

# Copy environment configuration
cp .env.example .env
# Edit .env to add your API keys (see README.md for details)

# Prepare the database
bin/rails db:prepare

# Build frontend assets
yarn build && yarn build:css

# Start the development server
bin/dev
```

### Running with Docker Compose

For the full environment including Temporal:

```bash
docker compose up
```

This starts PostgreSQL, Temporal, Temporal UI, the Rails app, and the Temporal worker process.

## Running Tests

```bash
# Run the full test suite
bin/rspec

# Run a specific test file
bin/rspec spec/models/project_spec.rb

# Run a specific test by line number
bin/rspec spec/models/project_spec.rb:42

# Run tests matching a pattern
bin/rspec --tag focus
```

The test suite uses:

- **RSpec** for test framework
- **Factory Bot** for test data
- **WebMock** for HTTP stubbing
- **SimpleCov** for coverage (target: 80%+)

### Before Submitting

Ensure all checks pass:

```bash
bin/rspec                    # Tests pass
bin/rubocop                  # No linting issues
bin/brakeman                 # No security warnings
```

Or run everything at once:

```bash
bin/ci
```

## Code Style

Paid follows the [rubocop-rails-omakase](https://github.com/rails/rubocop-rails-omakase) style guide (StandardRB-based). Key conventions:

- `frozen_string_literal: true` at the top of all Ruby files
- Maximum line length: 120 characters
- Classes target ~100 lines, methods target ~5 lines
- Maximum 4 parameters per method

### Service Objects

Business logic lives in service objects using [Servo](https://github.com/martinstreicher/servo), organized with verb-noun naming:

```ruby
# app/services/agent_runs/execute.rb
module AgentRuns
  class Execute < Servo::Base
    # ...
  end
end
```

### Logging

Use structured JSON logging with consistent component names:

```ruby
Rails.logger.info(
  message: "agent_execution.started",
  agent_run_id: agent_run.id,
  project_id: project.id
)
```

### Database Conventions

- UUIDs for external-facing IDs, bigints for internal foreign keys
- Always add foreign key constraints and index foreign keys
- Use migrations, never edit `db/schema.rb` directly

## Submitting Changes

1. **Create a branch** from `main`:

   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes** following the code style above

3. **Write tests** for new functionality

4. **Run checks**:

   ```bash
   bin/rspec && bin/rubocop && bin/brakeman
   ```

5. **Commit** with a clear message:

   ```bash
   git commit -m "feat: add widget support to projects"
   ```

6. **Push and open a PR** against `main`

### Commit Message Format

Use conventional commit prefixes:

- `feat:` New features
- `fix:` Bug fixes
- `docs:` Documentation changes
- `refactor:` Code changes that neither fix bugs nor add features
- `test:` Adding or updating tests
- `chore:` Build process, CI, dependency updates

### PR Guidelines

- Keep PRs focused on a single concern
- Include a clear description of what and why
- Reference related issues (e.g., `Closes #42`)
- Ensure CI passes before requesting review

## Architecture

For architectural context, see:

- [ARCHITECTURE.md](docs/ARCHITECTURE.md) - System design overview
- [DATA_MODEL.md](docs/DATA_MODEL.md) - Database schema and RBAC
- [AGENT_SYSTEM.md](docs/AGENT_SYSTEM.md) - Temporal workflows and agent execution
- [RDRs](docs/rdrs/) - Recommendation Decision Records for all major decisions

### Key Directories

```
app/
├── controllers/           # Thin controllers (Pundit-authorized)
├── models/                # ActiveRecord models with validations and scopes
├── services/              # Business logic (Servo service objects)
├── temporal/
│   ├── workflows/         # Temporal workflow definitions
│   └── activities/        # Temporal activity implementations
├── views/                 # ERB templates with Hotwire
└── policies/              # Pundit authorization policies
```

## Getting Help

- Open an issue for bugs or feature requests
- Check [ROADMAP.md](docs/ROADMAP.md) for planned work
- Review existing [RDRs](docs/rdrs/) before proposing architectural changes
