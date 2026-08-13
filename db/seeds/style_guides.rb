# frozen_string_literal: true

# Seeds default global style guides (account_id: nil, project_id: nil).
#
# Each guide is upserted by `name` within the global scope. Accounts can
# override any guide by creating a record with the same name at account
# or project scope (StyleGuide.resolve_for uses most-specific-wins).
#
# After upsert, raw_content is compressed asynchronously via
# StyleGuideCompressionJob whenever raw_content changes OR
# compressed_content is missing (the latter recovers from previously
# failed compression runs). Until compression completes, the injection
# layer falls back to truncated raw_content (8KB per guide).
#
# Content is intentionally language-agnostic unless a guide explicitly
# sets `language:`. Language-specific guides (Ruby, Rails, etc.) are
# seeded separately so only matching projects receive them.
#
# To add a new global default: append to GUIDES below. Re-running seeds
# is idempotent.

module Seeds
  module StyleGuides
    GUIDES = [
      {
        name: "Core Architecture",
        raw_content: <<~'MD'
          Architectural principles for code that orchestrates AI agents.

          ### Zero Framework Cognition (ZFC)

          Orchestration code stays mechanically simple. Delegate semantic reasoning to AI; keep mechanical/structural work in code.

          **Keep in code:** I/O, parsing known formats, structural safety checks (file exists? valid JSON? under size limit?), policy enforcement (budgets, rate limits, authorization), state management, typed error handling.

          **Delegate to AI:** quality judgments, plan composition, semantic analysis of issues / PRs / code, pattern matching for meaning, task decomposition.

          **Decision test:** if you are writing conditional logic that depends on understanding what some text *means*, that decision belongs in an AI call with a structured response schema — not in code. Regex or keyword matching for semantic intent is the canonical violation.

          Concretely, branching on whether an issue title "contains the word bug", whether a body is "long enough to be a large feature", or whether labels include "urgent" all bake in stale assumptions: titles lie, length does not indicate complexity, labels are inconsistent. Send the content to an AI call that returns a typed decision and let the surrounding code stay mechanical.

          ### AI-Generated Determinism (AGD)

          Use AI once at configuration time to generate deterministic artifacts that run without AI at runtime. Appropriate when input formats are stable and decisions can be pre-computed.

          Examples: style guide compression (analyze once, use the compressed output repeatedly), generated selection rules, pre-computed thresholds. The AI cost is paid once; the deterministic artifact is cheap to use thereafter.

          **AGD vs ZFC:** prefer AGD when the input format is stable and cost/latency matter; prefer ZFC when each input is unique and fresh context matters more than speed.

          ### Organize by Capability, Not by Workflow

          Group code by what it does (parsers, analyzers, formatters), not by which workflow uses it. When the same logic is duplicated under multiple workflow folders, bugs get fixed inconsistently and improvements do not propagate.

          When a new workflow needs an existing capability, compose the existing component rather than copying it. The cost of an extra abstraction is almost always lower than the cost of two implementations drifting apart.
        MD
      },
      {
        name: "Code Structure and Sizing",
        raw_content: <<~'MD'
          Concrete targets for maintainable code, drawn from Sandi Metz's *Practical Object-Oriented Design*.

          ### Size Targets

          - Classes target roughly 100 lines.
          - Methods target roughly 5 lines.
          - Methods take at most 4 parameters.
          - Controllers / entry-point handlers instantiate only one object.

          These are guidelines, not laws. A data structure with many attribute definitions may legitimately exceed 100 lines. A complex state transition may need a 20-line method. The point is to notice when you are exceeding the targets and make a conscious decision rather than drifting past them.

          When you intentionally exceed a target, leave a short comment explaining why so a future reader knows it was deliberate.

          ### When to Extract

          Extract a new method or class when:

          - A method does more than one thing ("does X, and then also does Y").
          - You are passing the same group of parameters to several methods — make it a parameter object.
          - A class has multiple reasons to change (single-responsibility violation).
          - You find yourself writing a comment to explain what a section does — name the section by extracting it.

          ### When NOT to Extract

          Do not extract when:

          - The extraction would just move complexity without reducing it.
          - The extracted code is only ever called from one place and reads naturally inline.
          - The extraction requires passing many parameters, creating tighter coupling than you started with.

          Premature extraction creates indirection that is harder to read than the original. Three similar lines is often better than a premature abstraction. Wait until the third occurrence before generalizing.
        MD
      },
      {
        name: "Structured Logging",
        raw_content: <<~'MD'
          Logs are searched, filtered, and aggregated. Structure them so machines can parse them and humans can find what they need.

          ### Format

          Use structured logs — typically JSON — with a stable `message` field naming the event using a `component.action` convention, plus separate structured fields for everything else. Avoid string-interpolating variable data into the message itself; that defeats grouping and full-text search.

          A completed agent run log should carry, as separate fields, the message name (for grouping), the run identifier (for correlation), the elapsed duration in milliseconds, and the terminal status — not all concatenated into a single sentence.

          ### Always Include

          - Correlation identifiers (request ID, run ID, workflow ID) so events can be traced across services.
          - Counts and sizes (record counts, byte sizes) for capacity analysis and anomaly detection.
          - Timing (`duration_ms`) on completion events.
          - A status code or outcome on terminal events.

          ### Never Include

          - Secrets, API keys, or tokens. Even short prefixes risk leakage in aggregated logs.
          - Full request or response payloads — log the shape, not the contents.
          - PII beyond what your privacy policy permits.
          - Information that is already present in the message name or adjacent fields.

          Auto-redaction in log middleware is a safety net, not the primary defense. Avoid putting secrets into log calls in the first place; treat anything written to logs as effectively public.

          ### Log Levels

          | Level   | Use For |
          |---------|---------|
          | `debug` | Method calls, internal state, decision points; off in production. |
          | `info`  | Significant events, completions, user actions, state transitions. |
          | `warn`  | Rate limits hit, fallbacks taken, retries, degraded functionality. |
          | `error` | Failures, exceptions, security-relevant events. |

          Reserve `error` for things that need human attention. A retry that succeeded or a fallback that worked belongs at `warn`, not `error`.
        MD
      },
      {
        name: "Testing",
        raw_content: <<~'MD'
          Tests verify behavior; they do not restate implementation.

          ### Philosophy

          Test behavior and interfaces, not implementation details. Tests coupled to implementation break during refactoring even when behavior is unchanged — which makes refactoring expensive and discourages improvement.

          From Sandi Metz's message-type taxonomy:

          - **Incoming query messages:** assert what they return.
          - **Incoming command messages:** assert the direct public side effects.
          - **Outgoing command messages:** mock them (verify they were sent).
          - **Private methods and outgoing queries:** do not test directly.

          Concretely: a test that calls a service and asserts the returned record's status is "pending" tests behavior. A test that asserts the service called a particular internal constructor with particular arguments tests implementation; refactoring the constructor will break the test even if behavior is unchanged.

          ### Mocking Strategy

          Mock external dependencies only. Never mock application code — that tests your mocks, not your code, and creates false confidence when the real integration is broken.

          Use dependency injection for external services instead of stubbing them globally. Never branch on the test environment inside production code (no "if running in tests" forks). Pass the test double in through the constructor or argument instead.

          ### No `sleep` in Tests

          Sleeping to wait for time-based behavior is both flaky and slow. Control time deterministically: set explicit timestamps when creating records, or use the test framework's time-travel helpers, so ordering and "expires after N seconds" behavior can be asserted without real wall-clock delay.

          ### Pending Tests (Strict)

          - A previously passing test must not become `pending`. Fix the code, fix the test, or delete the test with a written justification.
          - `pending` is allowed only for clearly identified future work with an issue reference, e.g. `pending: "supports parallel execution (issue #45)"`.
          - Untracked "fix later" or "not working" pending markers are technical debt that nobody sees and nobody fixes.

          ### Ephemeral PR Tests

          One-off system / integration tests that run in CI for a single PR but do **not** join the permanent suite.

          **When to use:**

          - End-to-end validation of a new feature before it has had real-world exposure.
          - Complex multi-step scenarios too specialized to run on every PR.
          - Migration paths, data transformations, or orchestration flows.
          - Exploratory integration tests that would be brittle as permanent fixtures.

          **When NOT to use:**

          - Regression tests — add them to the permanent `spec/` (or equivalent) tree instead.
          - Unit or service-level tests — they belong in the appropriate permanent test directory.
          - Anything that should keep running on every future PR.

          **How it works:**

          1. Add test files to `.ephemeral-tests/` on the PR branch (filename suffix matches the project's test framework — for example, `*_spec.rb` for RSpec).
          2. CI auto-detects the directory and runs the tests as a separate job.
          3. Same-repo PRs only; fork PRs are excluded for security.
          4. Results are posted as a PR comment.
          5. Remove the files before merging. A guard on the default branch rejects stray test files left behind.

          If an ephemeral test proves it would catch future regressions, **promote it** to the permanent suite before merging — do not just delete it.
        MD
      },
      {
        name: "Error Handling",
        raw_content: <<~'MD'
          Distinguish bugs from expected failures, and treat them differently.

          ### Philosophy

          **Internal errors are bugs. Let them crash.** A `nil` where you expected an object, a missing method, an unreachable state — surface these immediately with a clear stack trace. Limping along with corrupted state is worse than a loud failure.

          **External errors are expected.** Network timeouts, rate limits, invalid user input, unavailable third-party services — handle these with specific error types and clear recovery paths.

          ### Specific Error Types

          Avoid catch-all blocks that swallow every exception. Define distinct error classes for each failure mode so callers can react appropriately.

          For example, when integrating with a third-party API, define separate error types for: rate-limit exceeded (carries a `retry_after` value), invalid credentials, resource not found, and permission denied. Callers catching rate-limit can back off and retry; callers catching invalid credentials can prompt for re-authentication; callers catching not-found can fall through to creation. A single generic catch handles none of these well.

          A generic top-level catch is acceptable only at process boundaries — job entry points, request middleware — for the purpose of logging the failure and either re-raising or returning a structured failure response.

          ### Retries

          Use the framework's retry mechanism (workflow engine, job queue, HTTP client) for transient failures, with exponential backoff. Classify every error type as retryable or non-retryable:

          - **Business-rule failures** (budget exceeded, validation failure): non-retryable; the input will not become valid by retrying.
          - **Authentication failures** (invalid token, permission denied): non-retryable; needs human action.
          - **Transient infrastructure errors** (timeout, 503, rate limit): retryable with backoff.

          Do not retry without a classification. Silent infinite retries on a permanent failure burn budget and obscure the real problem.
        MD
      },
      {
        name: "Security",
        raw_content: <<~'MD'
          Defensive practices for code that handles untrusted input or sensitive data.

          ### Never Execute Untrusted Code Outside a Sandbox

          Agent-generated or user-provided code must run in an isolated container or sandbox. Never execute it in the main application process. This includes:

          - `eval`-style dynamic evaluation of strings as code.
          - Shell execution with user-provided commands or arguments interpolated into the command line.
          - Any "just for debugging" code path that runs untrusted input — if it is in production code, it is a remote code execution primitive.

          ### Validate File Paths Before Opening

          Reject path traversal before opening files. The pattern is:

          1. Resolve the user-supplied path to an absolute path, relative to a known base directory.
          2. Verify that the resolved absolute path starts with the absolute form of the base directory.
          3. Reject (do not silently fall back) if the check fails.

          Do not rely on string prefix checks against the raw input or the un-expanded base — symlinks, `..` segments, and absolute paths can escape. Always expand first, then compare absolutes.

          ### Do Not Log Secrets

          Auto-redaction in log middleware is a safety net, not a primary defense. Avoid putting secrets into log calls in the first place. Log identifying metadata (endpoint, token prefix for debugging, request ID), never the secret itself.

          Log aggregation systems often have broader access than the application secrets they record and persist longer. Treat anything written to logs as effectively public.

          ### Trust Boundaries

          - **Inside trusted code paths:** trust framework guarantees; do not re-validate types or invariants the framework already enforces. Over-validation adds noise and hides the real boundary checks.
          - **At system boundaries** — HTTP requests, webhook payloads, file inputs, external API responses, untrusted user-generated content fed into LLM prompts — validate aggressively. This is where defense-in-depth pays off.
        MD
      },
      {
        name: "Concurrency and Performance",
        raw_content: <<~'MD'
          Concrete rules for code that spawns threads, processes batches, or touches large datasets.

          ### Thread Management

          - **Always clean up in a finally / ensure block.** Resources released only on the happy path will leak under exceptions.
          - **Avoid shared mutable state without synchronization.** If two threads can write to the same variable, you have a race condition — solve it with a mutex, an atomic primitive, or by not sharing the state in the first place.
          - **Make intervals configurable.** Hard-coded sleeps prevent fast tests and operational tuning.
          - **Use cooperative stop signals.** A long-running worker should poll a stop flag and be wakeable from sleep, so shutdown is fast and deterministic. Avoid forcefully killing threads — they leak resources.

          ### Avoid O(n²) Over Large Collections

          Nested loops that scan one list inside another scale badly. When you need to look up items from one collection by a key from another, build an index (hash / map / dictionary) of the lookup collection once, then iterate the outer collection in linear time. This is the difference between "fine on a hundred records" and "five-minute query on production data".

          ### Batch Database Operations

          Avoid the N+1 anti-pattern in both reads and writes. When you need to create many records, use a bulk insert. When you need to read related data, eager-load it in one query instead of one query per row. Frameworks expose this as `insert_many`, `select_in`, `includes`, `select_related`, or similar — learn the idiom for your stack.

          ### Stream Large Record Sets

          Loading the entire result set into memory blows up on large tables. When iterating over a query that could return many rows, use the framework's batch-iteration helper so rows are fetched in chunks. This keeps memory bounded regardless of the result size.

          ### Cache Expensive Operations — With an Invalidation Strategy

          When the same expensive computation runs repeatedly with the same inputs, cache the result. **But only if you have an invalidation strategy.** An unbounded cache without invalidation is a memory leak with extra steps, and a cache without invalidation rules silently serves stale data the moment its inputs change.
        MD
      },
      {
        name: "Ruby Conventions",
        language: "ruby",
        raw_content: <<~'MD'
          Ruby-specific conventions for maintainable application code.

          ### File Headers and Encoding

          Add `# frozen_string_literal: true` at the top of Ruby files unless a file intentionally needs mutable string literals. When accepting external text input, normalize it to valid UTF-8 before storing, logging, or feeding it into downstream processing so invalid byte sequences fail at the boundary instead of deep in the app.

          ### Naming

          Use Ruby's conventional names:

          - Methods and variables use `snake_case`.
          - Classes and modules use `CamelCase`.
          - Predicate methods end in `?`.

          Do not add Java-style prefixes like `get_` or `set_`; in Ruby, readers and writers are expressed directly through method names and accessors. Prefer intention-revealing names over abbreviations.

          ### Parameters and Method Shape

          Avoid boolean flag parameters such as `notify: true` or `async: false`. A boolean argument usually means the method does two things; split it into separate methods or move the choice to the caller.

          ### Dead Code and Future Work

          Do not leave commented-out code in the codebase. Delete it and rely on git history if it is needed later.

          TODO comments require an issue reference in the exact form `# TODO(#123): short description`. Untracked TODOs turn into permanent clutter because nobody owns them.
        MD
      },
      {
        name: "Service Objects (Servo)",
        language: "ruby",
        raw_content: <<~'MD'
          Service objects hold business actions; keep them consistent and easy to find.

          ### Naming and Namespacing

          Name services with a verb-noun structure such as `AgentRuns::Create` or `Projects::Import`. Namespace by domain or capability, not by controller or workflow, so related operations stay together.

          Prefer placing services under `app/services/<domain>/` with a module hierarchy matching the path. If a new action belongs to an existing domain, add it there instead of creating a parallel folder with duplicated concepts.

          ### Servo Structure

          Use `Servo::Base` for service objects. Define explicit inputs and outputs at the boundary so callers can see the contract without reading the implementation.

          A service should:

          - Accept a small, well-defined set of inputs.
          - Return a clear result object or domain record.
          - Encapsulate one business action.

          Keep orchestration thin: validate structural preconditions, call the service, and handle the result. Push the business action itself into the service object.
        MD
      },
      {
        name: "Rails Patterns",
        language: "ruby",
        raw_content: <<~'MD'
          Rails-specific patterns for the current application stack.

          ### Controllers and Views

          Keep controllers thin. They should coordinate request/response concerns and delegate business work to service objects. Prefer one main object instantiation per controller action.

          The current view stack is ERB. Preserve existing ERB patterns unless a migration explicitly introduces a different component layer. Phlex is a future direction, not something to assume is already present.

          ### Hotwire and Turbo

          When working in interactive Rails UI flows, prefer existing Hotwire/Turbo patterns over adding custom JavaScript. Use Turbo Frames and Streams when they fit the current flow; do not introduce parallel interaction models without a clear reason.

          ### Background Work

          Use GoodJob for normal Rails background jobs. Reserve Temporal-oriented workflow logic for durable, multi-step orchestration concerns where workflow state and retries belong in the orchestrator rather than in ad hoc job chaining.
        MD
      },
      {
        name: "Database and Migrations",
        language: "ruby",
        raw_content: <<~'MD'
          Database rules for Rails schema changes and persistence code.

          ### IDs and Foreign Keys

          Use UUIDs for external-facing identifiers and bigints for internal foreign keys unless the surrounding schema establishes a different pattern. Add foreign key constraints and indexes for foreign keys.

          ### Migration Style

          Generate migrations with Rails generators instead of creating files manually. Prefer Rails migration helpers for tables, columns, indexes, and foreign keys rather than raw SQL.

          Raw SQL is the exception, not the default. Use it only when the database feature does not have an appropriate Rails helper. Row-level security and policy statements are the documented exception; keep that SQL minimal and isolated.

          ### schema.rb and fx

          The project uses `db/schema.rb`, not `structure.sql`. PostgreSQL functions and triggers should follow the `fx` workflow so schema dumping stays compatible with the Ruby schema format. Use `create_function`, `update_function`, `create_trigger`, and `update_trigger` instead of hand-written `CREATE FUNCTION` blocks.

          ### Logidze

          Add logidze only to tables where change history matters: settings, configuration, access control, financial records, and similar behavioral data. Do not add it to high-volume operational tables or append-only event streams where trigger overhead outweighs the audit value.
        MD
      }
    ].freeze

    def self.seed!
      GUIDES.each do |attrs|
        guide = ::StyleGuide.find_or_initialize_by(
          name: attrs[:name], account_id: nil, project_id: nil
        )
        guide.active = true if guide.new_record?
        guide.language = attrs[:language]
        guide.raw_content = attrs[:raw_content]

        # Recompress on: create, raw_content change, or a previously missing /
        # failed compression (so re-running seeds heals a stuck guide).
        needs_compression =
          guide.new_record? || guide.raw_content_changed? || guide.compressed_content.blank?

        guide.save!

        next unless needs_compression

        StyleGuideCompressionJob.perform_later(guide.id)
        Rails.logger.info(
          message: "seeds.style_guide_upserted",
          name: guide.name,
          style_guide_id: guide.id,
          compression_enqueued: true
        )
      end
    end
  end
end

Seeds::StyleGuides.seed!
