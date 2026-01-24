# RDR-013: Code Quality and Backpressure System

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata
- **Date**: 2025-01-23
- **Status**: Draft
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Hook execution tests, CI pipeline tests, linter integration tests

## Problem Statement

AI agents produce better code when they receive immediate feedback about their mistakes. Without feedback loops (backpressure), agents rely on humans to identify issues like:

1. Missing imports
2. Type errors
3. Style violations
4. Security vulnerabilities
5. Performance anti-patterns
6. Failing tests

This creates two problems:
1. **For agents working on Paid**: Changes that break builds or introduce vulnerabilities can reach the repository
2. **For agents working on user projects**: Without appropriate tooling, agents produce lower-quality code and require more human intervention

Requirements:
- Git hooks prevent low-quality commits/pushes from reaching Paid's repository
- CI workflows maintain Paid's quality and security
- Agents receive immediate feedback from linters, type checkers, and tests
- Paid can configure appropriate quality tools for projects it works on
- All feedback is structured for LLM consumption

## Context

### Background

The concept of "backpressure" in AI agent development refers to feedback mechanisms that help agents self-correct. From [Don't Waste Your Backpressure](https://banay.me/dont-waste-your-backpressure/):

> "This back pressure helps the agent identify mistakes as it progresses and models are now good enough that this feedback can keep them aligned to a task for much longer."

Without backpressure, humans spend their review time on trivial issues (missing semicolons, style violations) rather than substantive feedback. This doesn't scale.

### Technical Environment

- Ruby/Rails codebase for Paid itself
- Agents execute in Docker containers (see RDR-004)
- Projects may use various languages (Ruby, Python, JavaScript, TypeScript, Go, Rust, etc.)
- GitHub-based workflow (see RDR-012)

## Research Findings

### Investigation Process

1. Analyzed backpressure patterns for AI agents
2. Surveyed Ruby/Rails quality tooling ecosystem
3. Evaluated CI/CD security scanning tools
4. Researched multi-language linting approaches
5. Evaluated lefthook for Git hook management

### Key Discoveries

**Ruby/Rails Quality Tools:**

| Category | Tool | Purpose |
|----------|------|---------|
| Style | RuboCop | Style enforcement, auto-correction |
| Style | rubocop-rails | Rails-specific cops |
| Style | rubocop-rspec | RSpec-specific cops |
| Performance | rubocop-performance | Performance-focused cops |
| Performance | Fasterer | Suggests faster Ruby idioms |
| Performance | Derailed Benchmarks | Memory/boot time profiling |
| N+1 Detection | Bullet | Development N+1 detection |
| N+1 Detection | Prosopite | Production N+1 detection |
| Security | Brakeman | Static security analysis for Rails |
| Security | bundler-audit | Vulnerable dependency detection |

**CI/CD Security Tools:**

| Tool | Purpose | Target |
|------|---------|--------|
| Zizmor | GitHub Actions security scanner | Workflow files |
| Trivy | Container vulnerability scanner | Docker images |
| Gitleaks | Secret detection | Git history |
| Dependabot | Dependency updates | Gemfile, package.json, etc. |
| CodeQL | Semantic code analysis | Multiple languages |

**Multi-Language Linting:**

| Language | Primary Linter | Type Checker |
|----------|----------------|--------------|
| Ruby | RuboCop | Sorbet, Steep |
| Python | Ruff, Pylint | mypy, pyright |
| JavaScript | ESLint | TypeScript |
| TypeScript | ESLint | Built-in |
| Go | golangci-lint | Built-in |
| Rust | Clippy | Built-in |

**Lefthook Framework:**

[Lefthook](https://lefthook.dev) is a fast, polyglot Git hooks manager:
- Written in Go, extremely fast (~0.1s overhead)
- Single binary, no dependencies (unlike pre-commit which requires Python)
- Parallel hook execution by default
- Declarative `lefthook.yml` configuration
- Built-in support for partial file checking (staged files only)
- Works well in monorepos

**Feedback Quality for LLMs:**

Languages with excellent error messages (Rust, Elm, Python) provide better backpressure because errors include:
- Clear problem description
- Location (file, line, column)
- Suggested fixes
- Links to documentation

Tools that produce machine-readable output (JSON, SARIF) are easier to parse and present to agents.

## Proposed Solution

### Approach

Implement a three-layer quality system:

1. **Layer 1: Paid Self-Quality** - Git hooks and CI for Paid's own codebase
2. **Layer 2: Agent Feedback Loop** - Tools available in containers for immediate feedback
3. **Layer 3: Project Configuration** - Ability to add/configure quality tools in user projects

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    CODE QUALITY & BACKPRESSURE ARCHITECTURE                   │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ LAYER 1: PAID SELF-QUALITY                                              ││
│  │                                                                          ││
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐      ││
│  │  │   Pre-commit     │  │   Pre-push       │  │   CI Pipeline    │      ││
│  │  │   (lefthook)     │  │   (lefthook)     │  │   (GitHub)       │      ││
│  │  │                  │  │                  │  │                  │      ││
│  │  │ • RuboCop        │  │ • Full test      │  │ • All hooks      │      ││
│  │  │ • Fasterer       │  │   suite          │  │ • Security scan  │      ││
│  │  │ • Brakeman quick │  │ • Brakeman full  │  │ • PR Review      │      ││
│  │  │ • Gitleaks       │  │ • bundler-audit  │  │ • Zizmor         │      ││
│  │  │ • Trailing WS    │  │                  │  │ • Dependency     │      ││
│  │  └──────────────────┘  └──────────────────┘  └──────────────────┘      ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ LAYER 2: AGENT FEEDBACK LOOP                                            ││
│  │                                                                          ││
│  │  ┌─────────────────────────────────────────────────────────────────────┐││
│  │  │                    AGENT CONTAINER                                  │││
│  │  │                                                                      │││
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────┐ │││
│  │  │  │   Linters   │  │   Type      │  │   Tests     │  │   Build    │ │││
│  │  │  │   (fast)    │  │   Checkers  │  │   (fast)    │  │   System   │ │││
│  │  │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └─────┬──────┘ │││
│  │  │         │                │                │               │         │││
│  │  │         └────────────────┴────────────────┴───────────────┘         │││
│  │  │                                   │                                  │││
│  │  │                                   ▼                                  │││
│  │  │                    ┌─────────────────────────────┐                   │││
│  │  │                    │   Structured Feedback       │                   │││
│  │  │                    │   (JSON/SARIF → Agent)      │                   │││
│  │  │                    └─────────────────────────────┘                   │││
│  │  └─────────────────────────────────────────────────────────────────────┘││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │ LAYER 3: PROJECT CONFIGURATION                                          ││
│  │                                                                          ││
│  │  ┌──────────────────────────────────────────────────────────────────┐   ││
│  │  │                    QualityConfigurator                            │   ││
│  │  │                                                                   │   ││
│  │  │  • Detects project language/framework                            │   ││
│  │  │  • Suggests appropriate tools                                    │   ││
│  │  │  • Generates config files (.rubocop.yml, lefthook.yml)           │   ││
│  │  │  • Adds CI workflows                                             │   ││
│  │  │  • Updates dependencies (Gemfile, package.json, etc.)            │   ││
│  │  └──────────────────────────────────────────────────────────────────┘   ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Layered approach**: Different quality needs at different stages
2. **Fail fast**: Catch issues at commit time, not PR review time
3. **Structured output**: Machine-readable feedback for agents
4. **Language detection**: Automatically apply appropriate tools
5. **Configurable strictness**: Projects can adjust thresholds

### Implementation Example

#### Layer 1: Paid's Git Hooks

```yaml
# lefthook.yml (for Paid itself)
pre-commit:
  parallel: true
  commands:
    rubocop:
      glob: "*.{rb,rake}"
      run: bundle exec rubocop --force-exclusion {staged_files}

    fasterer:
      glob: "*.rb"
      run: bundle exec fasterer {staged_files}

    brakeman-quick:
      run: bundle exec brakeman -q --no-pager --skip-files spec/

    erb-lint:
      glob: "*.erb"
      run: bundle exec erb_lint {staged_files}

    trailing-whitespace:
      run: git diff --check --cached

    yaml-check:
      glob: "*.{yml,yaml}"
      run: ruby -e "require 'yaml'; ARGV.each { |f| YAML.load_file(f) }" {staged_files}

    gitleaks:
      run: gitleaks protect --staged --no-banner

pre-push:
  parallel: false
  commands:
    rspec:
      run: bundle exec rspec --fail-fast

    brakeman-full:
      run: bundle exec brakeman --no-pager

    bundler-audit:
      run: bundle exec bundler-audit check --update
```

#### Layer 1: Paid's CI Pipeline

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read
  security-events: write

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true

      - name: RuboCop
        run: bundle exec rubocop --format github

      - name: Fasterer
        run: bundle exec fasterer

      - name: ERB Lint
        run: bundle exec erb_lint --lint-all

  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true

      - name: Brakeman
        run: bundle exec brakeman --format sarif -o brakeman.sarif

      - name: Upload Brakeman SARIF
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: brakeman.sarif

      - name: Bundler Audit
        run: bundle exec bundler-audit check --update

  zizmor:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Zizmor
        uses: woodruffw/zizmor-action@v1
        with:
          args: --format sarif -o zizmor.sarif .github/workflows/

      - name: Upload Zizmor SARIF
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: zizmor.sarif

  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: postgres
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 5432:5432

    steps:
      - uses: actions/checkout@v4

      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true

      - name: Setup database
        run: bundle exec rails db:setup
        env:
          RAILS_ENV: test
          DATABASE_URL: postgres://postgres:postgres@localhost:5432/paid_test

      - name: RSpec
        run: bundle exec rspec --format documentation --format RspecJunitFormatter --out rspec.xml
        env:
          RAILS_ENV: test
          DATABASE_URL: postgres://postgres:postgres@localhost:5432/paid_test

      - name: Upload test results
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: test-results
          path: rspec.xml

  performance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true

      - name: Derailed - Memory
        run: bundle exec derailed bundle:mem 2>/dev/null | head -50
        continue-on-error: true

      - name: Boot time benchmark
        run: time bundle exec rails runner "puts 'Boot complete'"

  pr-review:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true

      - name: AI PR Review
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
        run: |
          bundle exec rails runner "PrReviewService.new.review_pr(
            repo: '${{ github.repository }}',
            pr_number: ${{ github.event.pull_request.number }}
          )"
```

#### Layer 1: PR Review Workflow

Paid reviews its own PRs using an AI-powered review workflow:

```ruby
# app/services/pr_review_service.rb
class PrReviewService
  REVIEW_PROMPT = <<~PROMPT
    Review this pull request for:
    1. **Security Issues**: SQL injection, XSS, CSRF, secrets exposure, unsafe deserialization
    2. **Performance**: N+1 queries, missing indexes, inefficient algorithms, memory leaks
    3. **Rails Best Practices**: Convention violations, antipatterns, missing validations
    4. **Code Quality**: Complexity, duplication, unclear naming, missing error handling
    5. **Test Coverage**: Missing tests, edge cases not covered, brittle tests

    Be specific. Reference file:line for each issue.
    Only comment on actual problems, not style preferences.
    If the code looks good, say so briefly.
  PROMPT

  def initialize(client: nil)
    @client = client || Anthropic::Client.new
    @github = Octokit::Client.new(access_token: ENV["GITHUB_TOKEN"])
  end

  def review_pr(repo:, pr_number:)
    pr = @github.pull_request(repo, pr_number)
    diff = @github.pull_request_files(repo, pr_number)

    # Build context for review
    context = build_review_context(pr, diff)

    # Get AI review
    response = @client.messages.create(
      model: "claude-sonnet-4-20250514",
      max_tokens: 4096,
      system: REVIEW_PROMPT,
      messages: [{ role: "user", content: context }]
    )

    review_body = response.content.first.text

    # Post review as PR comment
    @github.create_pull_request_review(
      repo,
      pr_number,
      body: review_body,
      event: determine_review_event(review_body)
    )
  end

  private

  def build_review_context(pr, diff)
    <<~CONTEXT
      ## Pull Request: #{pr.title}

      #{pr.body}

      ## Changed Files:

      #{diff.map { |f| format_file_diff(f) }.join("\n\n")}
    CONTEXT
  end

  def format_file_diff(file)
    <<~FILE
      ### #{file.filename} (+#{file.additions}/-#{file.deletions})

      ```diff
      #{file.patch}
      ```
    FILE
  end

  def determine_review_event(review_body)
    # If review mentions critical issues, request changes
    if review_body.match?(/security|vulnerability|critical|must fix/i)
      "REQUEST_CHANGES"
    else
      "COMMENT"
    end
  end
end
```

This self-review catches issues before human reviewers spend time on them:
- Security vulnerabilities flagged immediately
- Performance antipatterns identified
- Convention violations highlighted
- Reduces cognitive load on human reviewers

#### Layer 2: Agent Feedback Service

```ruby
# app/services/quality_feedback_service.rb
class QualityFeedbackService
  TOOL_CONFIGS = {
    ruby: {
      linter: { cmd: "rubocop --format json", parser: :rubocop },
      security: { cmd: "brakeman --format json --quiet", parser: :brakeman },
      tests: { cmd: "rspec --format json", parser: :rspec }
    },
    python: {
      linter: { cmd: "ruff check --output-format json", parser: :ruff },
      type_check: { cmd: "mypy --output json", parser: :mypy },
      tests: { cmd: "pytest --json-report", parser: :pytest }
    },
    javascript: {
      linter: { cmd: "eslint --format json", parser: :eslint },
      tests: { cmd: "npm test -- --json", parser: :jest }
    },
    typescript: {
      linter: { cmd: "eslint --format json", parser: :eslint },
      type_check: { cmd: "tsc --noEmit 2>&1", parser: :typescript },
      tests: { cmd: "npm test -- --json", parser: :jest }
    },
    go: {
      linter: { cmd: "golangci-lint run --out-format json", parser: :golangci },
      tests: { cmd: "go test -json ./...", parser: :gotest }
    },
    rust: {
      linter: { cmd: "cargo clippy --message-format json", parser: :clippy },
      tests: { cmd: "cargo test --message-format json", parser: :cargo_test }
    }
  }.freeze

  def initialize(worktree_path:, language:)
    @worktree_path = worktree_path
    @language = language.to_sym
    @tools = TOOL_CONFIGS[@language] || {}
  end

  # Run all available checks and return structured feedback
  def run_all_checks
    results = {}

    @tools.each do |check_type, config|
      results[check_type] = run_check(check_type, config)
    end

    FeedbackResult.new(
      language: @language,
      checks: results,
      summary: generate_summary(results),
      agent_prompt: generate_agent_prompt(results)
    )
  end

  # Run a specific check
  def run_check(check_type, config = nil)
    config ||= @tools[check_type]
    return nil unless config

    output, status = execute_in_worktree(config[:cmd])
    parsed = parse_output(output, config[:parser])

    CheckResult.new(
      type: check_type,
      success: status.success? && parsed[:errors].empty?,
      errors: parsed[:errors],
      warnings: parsed[:warnings],
      raw_output: output
    )
  end

  private

  def execute_in_worktree(cmd)
    stdout, stderr, status = Open3.capture3(
      cmd,
      chdir: @worktree_path,
      env: { "CI" => "true" }  # Many tools behave better in CI mode
    )
    [stdout + stderr, status]
  end

  def parse_output(output, parser)
    case parser
    when :rubocop
      parse_rubocop(output)
    when :brakeman
      parse_brakeman(output)
    when :rspec
      parse_rspec(output)
    when :eslint
      parse_eslint(output)
    when :typescript
      parse_typescript(output)
    else
      { errors: [], warnings: [] }
    end
  rescue JSON::ParserError
    # Fall back to line-by-line parsing
    parse_generic(output)
  end

  def parse_rubocop(output)
    data = JSON.parse(output)
    errors = []
    warnings = []

    data["files"].each do |file|
      file["offenses"].each do |offense|
        item = {
          file: file["path"],
          line: offense["location"]["start_line"],
          column: offense["location"]["start_column"],
          message: offense["message"],
          rule: offense["cop_name"],
          severity: offense["severity"],
          correctable: offense["correctable"]
        }

        if %w[error fatal].include?(offense["severity"])
          errors << item
        else
          warnings << item
        end
      end
    end

    { errors: errors, warnings: warnings }
  end

  def parse_brakeman(output)
    data = JSON.parse(output)
    errors = []
    warnings = []

    data["warnings"].each do |warning|
      item = {
        file: warning["file"],
        line: warning["line"],
        message: warning["message"],
        rule: warning["warning_type"],
        severity: warning["confidence"],
        link: warning["link"]
      }

      if warning["confidence"] == "High"
        errors << item
      else
        warnings << item
      end
    end

    { errors: errors, warnings: warnings }
  end

  def generate_summary(results)
    total_errors = results.values.compact.sum { |r| r.errors.size }
    total_warnings = results.values.compact.sum { |r| r.warnings.size }
    passed_checks = results.values.compact.count(&:success)
    total_checks = results.values.compact.size

    {
      total_errors: total_errors,
      total_warnings: total_warnings,
      passed_checks: passed_checks,
      total_checks: total_checks,
      status: total_errors.zero? ? :pass : :fail
    }
  end

  def generate_agent_prompt(results)
    return "All checks passed." if results.values.all?(&:success)

    prompt = "The following issues were found:\n\n"

    results.each do |check_type, result|
      next if result.nil? || result.success

      prompt += "## #{check_type.to_s.titleize}\n\n"

      result.errors.first(10).each do |error|
        prompt += "- **#{error[:file]}:#{error[:line]}** - #{error[:message]}"
        prompt += " (#{error[:rule]})" if error[:rule]
        prompt += " [correctable]" if error[:correctable]
        prompt += "\n"
      end

      if result.errors.size > 10
        prompt += "- ... and #{result.errors.size - 10} more errors\n"
      end

      prompt += "\n"
    end

    prompt += "Please fix these issues before continuing."
    prompt
  end

  class FeedbackResult
    attr_reader :language, :checks, :summary, :agent_prompt

    def initialize(language:, checks:, summary:, agent_prompt:)
      @language = language
      @checks = checks
      @summary = summary
      @agent_prompt = agent_prompt
    end

    def success?
      summary[:status] == :pass
    end

    def to_h
      {
        language: language,
        summary: summary,
        checks: checks.transform_values(&:to_h),
        agent_prompt: agent_prompt
      }
    end
  end

  class CheckResult
    attr_reader :type, :success, :errors, :warnings, :raw_output

    def initialize(type:, success:, errors:, warnings:, raw_output:)
      @type = type
      @success = success
      @errors = errors
      @warnings = warnings
      @raw_output = raw_output
    end

    def success?
      @success
    end

    def to_h
      {
        type: type,
        success: success,
        error_count: errors.size,
        warning_count: warnings.size,
        errors: errors.first(20),  # Limit for API response
        warnings: warnings.first(20)
      }
    end
  end
end
```

#### Layer 2: Agent Execution with Feedback Loop

```ruby
# app/workflows/agent_execution_workflow.rb (updated)
class AgentExecutionWorkflow
  def execute(task)
    # ... container setup ...

    max_feedback_loops = 3
    feedback_loops = 0

    loop do
      # Run the agent
      result = workflow.execute_activity(
        RunAgentActivity,
        { agent_type: task.agent_type, prompt: current_prompt, ... },
        start_to_close_timeout: 30.minutes
      )

      break if result[:success] == false  # Agent failed entirely

      # Run quality checks
      feedback = workflow.execute_activity(
        RunQualityChecksActivity,
        { worktree_path: worktree_path, language: task.language },
        start_to_close_timeout: 5.minutes
      )

      if feedback[:summary][:status] == :pass
        # All checks passed, create PR
        break
      end

      feedback_loops += 1

      if feedback_loops >= max_feedback_loops
        # Too many attempts, create PR anyway with quality warnings
        result[:quality_warnings] = feedback[:agent_prompt]
        break
      end

      # Feed errors back to agent for another attempt
      current_prompt = <<~PROMPT
        Your previous changes had the following issues:

        #{feedback[:agent_prompt]}

        Please fix these issues. Do not introduce new functionality,
        only fix the reported problems.
      PROMPT

      Rails.logger.info("Quality feedback loop #{feedback_loops}: #{feedback[:summary]}")
    end

    # ... PR creation ...
  end
end
```

#### Layer 3: Project Quality Configurator

```ruby
# app/services/quality_configurator_service.rb
class QualityConfiguratorService
  LANGUAGE_DETECTORS = {
    ruby: -> (path) { File.exist?(File.join(path, "Gemfile")) },
    python: -> (path) {
      File.exist?(File.join(path, "pyproject.toml")) ||
      File.exist?(File.join(path, "requirements.txt"))
    },
    javascript: -> (path) {
      package_json = File.join(path, "package.json")
      File.exist?(package_json) && !JSON.parse(File.read(package_json)).dig("devDependencies", "typescript")
    },
    typescript: -> (path) {
      File.exist?(File.join(path, "tsconfig.json"))
    },
    go: -> (path) { File.exist?(File.join(path, "go.mod")) },
    rust: -> (path) { File.exist?(File.join(path, "Cargo.toml")) }
  }.freeze

  TOOL_TEMPLATES = {
    ruby: {
      gemfile_additions: <<~RUBY,
        group :development, :test do
          gem "rubocop", require: false
          gem "rubocop-performance", require: false
          gem "rubocop-rails", require: false
          gem "rubocop-rspec", require: false
          gem "fasterer", require: false
          gem "brakeman", require: false
          gem "bundler-audit", require: false
        end
      RUBY
      rubocop_config: <<~YAML,
        require:
          - rubocop-performance
          - rubocop-rails
          - rubocop-rspec

        AllCops:
          NewCops: enable
          TargetRubyVersion: 3.2
          Exclude:
            - 'db/schema.rb'
            - 'bin/**/*'
            - 'vendor/**/*'

        Style/Documentation:
          Enabled: false

        Metrics/BlockLength:
          Exclude:
            - 'spec/**/*'
            - 'config/routes.rb'
      YAML
      lefthook_config: <<~YAML
        pre-commit:
          parallel: true
          commands:
            rubocop:
              glob: "*.{rb,rake}"
              run: bundle exec rubocop --force-exclusion {staged_files}
            brakeman:
              run: bundle exec brakeman -q --no-pager
      YAML
    },
    python: {
      pyproject_additions: <<~TOML,
        [tool.ruff]
        line-length = 100
        select = ["E", "F", "W", "I", "UP", "B", "C4", "SIM"]

        [tool.mypy]
        strict = true
        ignore_missing_imports = true
      TOML
      lefthook_config: <<~YAML
        pre-commit:
          parallel: true
          commands:
            ruff:
              glob: "*.py"
              run: ruff check --fix {staged_files}
            ruff-format:
              glob: "*.py"
              run: ruff format {staged_files}
            mypy:
              glob: "*.py"
              run: mypy {staged_files}
      YAML
    },
    typescript: {
      package_additions: {
        "devDependencies" => {
          "eslint" => "^8.0.0",
          "@typescript-eslint/parser" => "^6.0.0",
          "@typescript-eslint/eslint-plugin" => "^6.0.0",
          "prettier" => "^3.0.0",
          "lefthook" => "^1.6.0"
        }
      },
      eslint_config: <<~JSON,
        {
          "parser": "@typescript-eslint/parser",
          "plugins": ["@typescript-eslint"],
          "extends": [
            "eslint:recommended",
            "plugin:@typescript-eslint/recommended"
          ],
          "rules": {
            "@typescript-eslint/explicit-function-return-type": "warn",
            "@typescript-eslint/no-unused-vars": "error"
          }
        }
      JSON
      lefthook_config: <<~YAML
        pre-commit:
          parallel: true
          commands:
            eslint:
              glob: "*.{ts,tsx}"
              run: npx eslint --fix {staged_files}
            typecheck:
              run: npx tsc --noEmit
      YAML
    }
  }.freeze

  def initialize(project_path:)
    @project_path = project_path
    @detected_languages = detect_languages
  end

  def detect_languages
    LANGUAGE_DETECTORS.select { |lang, detector| detector.call(@project_path) }.keys
  end

  def suggest_configuration
    suggestions = []

    @detected_languages.each do |lang|
      template = TOOL_TEMPLATES[lang]
      next unless template

      suggestions << {
        language: lang,
        files_to_create: files_for_language(lang, template),
        dependencies_to_add: dependencies_for_language(lang, template),
        ci_workflow: ci_workflow_for_language(lang)
      }
    end

    suggestions
  end

  def apply_configuration(languages: @detected_languages, include_ci: true)
    changes = []

    languages.each do |lang|
      template = TOOL_TEMPLATES[lang]
      next unless template

      # Create config files
      files_for_language(lang, template).each do |file_path, content|
        full_path = File.join(@project_path, file_path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, content)
        changes << { action: :create, file: file_path }
      end

      # Add dependencies
      add_dependencies(lang, template)
      changes << { action: :update, file: dependency_file(lang) }
    end

    if include_ci
      # Create unified CI workflow
      ci_path = File.join(@project_path, ".github/workflows/ci.yml")
      FileUtils.mkdir_p(File.dirname(ci_path))
      File.write(ci_path, generate_ci_workflow)
      changes << { action: :create, file: ".github/workflows/ci.yml" }
    end

    # Create lefthook config
    lefthook_path = File.join(@project_path, "lefthook.yml")
    File.write(lefthook_path, generate_lefthook_config)
    changes << { action: :create, file: "lefthook.yml" }

    changes
  end

  private

  def files_for_language(lang, template)
    case lang
    when :ruby
      { ".rubocop.yml" => template[:rubocop_config] }
    when :typescript
      { ".eslintrc.json" => template[:eslint_config] }
    else
      {}
    end
  end

  def dependencies_for_language(lang, template)
    case lang
    when :ruby
      template[:gemfile_additions]
    when :python
      template[:pyproject_additions]
    when :typescript
      template[:package_additions]
    else
      nil
    end
  end

  def dependency_file(lang)
    case lang
    when :ruby then "Gemfile"
    when :python then "pyproject.toml"
    when :javascript, :typescript then "package.json"
    when :go then "go.mod"
    when :rust then "Cargo.toml"
    end
  end

  def generate_lefthook_config
    # Combine lefthook configs from all detected languages
    config = { "pre-commit" => { "parallel" => true, "commands" => {} } }

    @detected_languages.each do |lang|
      template = TOOL_TEMPLATES[lang]
      next unless template&.dig(:lefthook_config)

      lang_config = YAML.safe_load(template[:lefthook_config])
      config["pre-commit"]["commands"].merge!(
        lang_config.dig("pre-commit", "commands") || {}
      )
    end

    config.to_yaml
  end

  def generate_ci_workflow
    # Generate unified CI workflow for all detected languages
    # ... implementation
  end
end
```

## Alternatives Considered

### Alternative 1: CI-Only Quality Checks

**Description**: Only run quality checks in CI, not locally via hooks

**Pros**:
- Simpler setup (no local hooks)
- Faster local development
- Centralized enforcement

**Cons**:
- Slow feedback loop (wait for CI)
- Wasted CI resources on trivial issues
- PRs opened with obvious problems

**Reason for rejection**: Backpressure principle requires immediate feedback. Waiting for CI defeats the purpose.

### Alternative 2: MegaLinter for Everything

**Description**: Use MegaLinter as the single tool for all quality checks

**Pros**:
- Single tool to configure
- Supports many languages
- Docker-based, consistent

**Cons**:
- Slower than native tools
- Less flexible configuration
- Overkill for simple projects

**Reason for rejection**: Native tools provide better error messages and faster feedback. MegaLinter can supplement but not replace.

### Alternative 3: Language Server Protocol (LSP) Integration

**Description**: Use LSP servers for real-time feedback instead of batch linting

**Pros**:
- Real-time feedback
- Rich editor integration
- Same logic as IDE

**Cons**:
- Complex to integrate with agents
- Memory intensive
- Not all tools have LSP

**Reason for rejection**: Batch linting is simpler and sufficient for agent feedback loops. LSP could be added later for specific use cases.

### Alternative 4: Custom Quality Framework

**Description**: Build a custom quality framework instead of using existing tools

**Pros**:
- Perfectly tailored
- Unified output format
- Full control

**Cons**:
- Massive development effort
- Maintenance burden
- Miss community improvements

**Reason for rejection**: Leverage existing ecosystem. Focus on integration, not reinvention.

## Trade-offs and Consequences

### Positive Consequences

- **Faster issue detection**: Problems caught at commit, not review
- **Better agent output**: Agents self-correct without human intervention
- **Consistent quality**: Same standards enforced everywhere
- **Security by default**: Vulnerability scanning built-in
- **Reduced review burden**: Human reviewers focus on logic, not style

### Negative Consequences

- **Setup complexity**: Lefthook requires installation (though it's a single binary)
- **Slower commits**: Hooks add time to commit process
- **False positives**: Some linter rules may be too strict
- **Tool maintenance**: Must keep tools updated

### Risks and Mitigations

- **Risk**: Hooks slow down development too much
  **Mitigation**: Run only fast checks pre-commit; slow checks pre-push or CI only

- **Risk**: Agents get stuck in feedback loops
  **Mitigation**: Limit feedback iterations; create PR with warnings after max attempts

- **Risk**: Tools produce incomprehensible errors
  **Mitigation**: Use tools with good error messages; format output for LLM consumption

## Implementation Plan

### Prerequisites

- [ ] Lefthook installation and configuration
- [ ] RuboCop configuration expertise
- [ ] CI/CD pipeline experience
- [ ] Docker container tool installation

### Step-by-Step Implementation

#### Phase 1: Paid Self-Quality

1. Create `lefthook.yml` for Paid
2. Add quality gems to Gemfile
3. Configure RuboCop with appropriate rules
4. Set up Brakeman for security scanning
5. Create GitHub Actions CI workflow
6. Add Zizmor for workflow security

#### Phase 2: Agent Feedback Loop (Week 3-4)

1. Install quality tools in agent container image
2. Implement `QualityFeedbackService`
3. Add `RunQualityChecksActivity` to Temporal
4. Update `AgentExecutionWorkflow` with feedback loop
5. Test feedback loop with various error types

#### Phase 3: Project Configuration (Week 5-6)

1. Implement `QualityConfiguratorService`
2. Create language detection logic
3. Build config templates for each language
4. Add UI for quality configuration
5. Create workflow for applying configurations

### Files to Create

**For Paid itself:**
- `lefthook.yml`
- `.rubocop.yml`
- `.github/workflows/ci.yml`
- `.github/workflows/security.yml`

**For quality system:**
- `app/services/quality_feedback_service.rb`
- `app/services/quality_configurator_service.rb`
- `app/activities/run_quality_checks_activity.rb`
- `lib/quality_parsers/` (various output parsers)

### Dependencies

**Gemfile additions:**
```ruby
group :development, :test do
  gem "rubocop", "~> 1.60", require: false
  gem "rubocop-performance", require: false
  gem "rubocop-rails", require: false
  gem "rubocop-rspec", require: false
  gem "fasterer", require: false
  gem "brakeman", require: false
  gem "bundler-audit", require: false
end

group :development do
  gem "erb_lint", require: false
  gem "derailed_benchmarks", require: false
end

group :development, :production do
  gem "prosopite"  # Production N+1 detection
end
```

**Lefthook installation:**
```bash
# macOS
brew install lefthook

# Or via npm (for CI/cross-platform)
npm install -g lefthook

# Initialize in repo
lefthook install
```

## Validation

### Testing Approach

1. Hook execution tests (do hooks run correctly?)
2. Parser tests (is tool output parsed correctly?)
3. Feedback loop tests (do agents receive proper feedback?)
4. Configuration tests (are configs generated correctly?)

### Test Scenarios

1. **Scenario**: Commit with RuboCop violations
   **Expected Result**: Lefthook pre-commit blocks commit, shows violations

2. **Scenario**: Push with security vulnerability
   **Expected Result**: Lefthook pre-push blocks push, shows Brakeman warning

3. **Scenario**: Agent produces code with type errors
   **Expected Result**: Feedback loop provides structured error, agent fixes

4. **Scenario**: Configure quality for Python project
   **Expected Result**: Correct ruff, mypy, pytest configs generated

### Performance Validation

- Pre-commit hooks < 5 seconds for typical changes
- Pre-push hooks < 60 seconds for full suite
- Quality feedback generation < 30 seconds

### Security Validation

- Brakeman catches known vulnerability patterns
- bundler-audit detects vulnerable gems
- Zizmor catches workflow security issues
- Gitleaks prevents secret commits

## References

### Requirements & Standards

- [Don't Waste Your Backpressure](https://banay.me/dont-waste-your-backpressure/) - Backpressure concept
- OWASP guidelines for security scanning

### Dependencies

- [Lefthook](https://lefthook.dev/) - Fast Git hooks manager
- [RuboCop](https://rubocop.org/) - Ruby linter
- [Brakeman](https://brakemanscanner.org/) - Rails security
- [Zizmor](https://github.com/woodruffw/zizmor) - GitHub Actions security
- [Ruff](https://github.com/astral-sh/ruff) - Python linter

### Research Resources

- [Git Hooks](https://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks) - Git documentation
- SARIF format specification
- GitHub Code Scanning integration

## Notes

- Lefthook chosen over pre-commit for speed (Go binary vs Python) and simpler setup
- Prosopite for production N+1 detection vs Bullet for development
- Some tools (Sorbet, Steep) may be too strict for initial setup
- GitHub Advanced Security provides additional SARIF integration
- Agent container image should include all language tools, not just Ruby
- PR review workflow can be adjusted to use different models based on cost/quality needs
- Consider caching PR review results to avoid re-reviewing unchanged files
