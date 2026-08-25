# frozen_string_literal: true

# Seed default prompts used by Paid agents and supporting services.
#
# Each entry represents a global prompt template that can be:
#   - Resolved at runtime via Prompts::Render or Prompts::Resolve
#   - Iterated on via the PromptsController UI
#   - Versioned, A/B tested, and tracked for cost/quality metrics
#
# When a prompt's template or variables change here, the seed creates a new
# version (versions are immutable). Use `db:seed:replant` during development
# if you want to reset history.

upsert_global_prompt = lambda do |slug:, name:, description:, category:, template:, variables:|
  prompt = Prompt.find_or_initialize_by(slug: slug, account_id: nil, project_id: nil)

  if prompt.new_record?
    prompt.assign_attributes(
      name: name,
      description: description,
      category: category,
      active: true
    )
  else
    prompt.name ||= name         # preserve user edits; only fill when blank
    prompt.description ||= description
    prompt.category ||= category
    prompt.active = true if prompt.active.nil?
  end

  prompt.save!

  current = prompt.current_version
  normalize = ->(t) { t.to_s.strip }

  if current.nil? ||
     normalize.call(current.template) != normalize.call(template) ||
     current.variables != variables
    change_notes = current.nil? ? "Initial version from seeds" : "Updated from seeds: template and/or variables changed"

    prompt.create_version!(
      template: template,
      variables: variables,
      created_by: "seed",
      change_notes: change_notes
    )

    Rails.logger.info(message: "seeds.created_prompt", slug: slug)
  end
end

var = ->(name, description, required: true) { { "name" => name, "required" => required, "description" => description } }

# ----------------------------------------------------------------------------
# chat.system_prompt — Default system prompt for interactive chat sessions
# Used by: ChatSessions::BuildSystemPrompt (fallback when no custom prompt set)
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "chat.system_prompt",
  name: "Chat System Prompt",
  description: "Default system prompt for interactive chat sessions. Provides base identity and capabilities for the AI assistant.",
  category: "planning",
  template: <<~'TEMPLATE',
    You are an AI assistant helping manage software projects via Paid, a platform for AI-driven development.
    You can help with:
    - Designing features and discussing implementation approaches
    - Debugging issues by inspecting code, logs, and running commands
    - Managing projects, issues, and agent runs through Paid's tools
    - Answering questions about codebases and project status

    When the user asks you to perform actions (trigger runs, list projects, etc.), use the available tools.
    Be concise and technical. Ask clarifying questions when the request is ambiguous.
  TEMPLATE
  variables: []
)

# ----------------------------------------------------------------------------
# coding.issue_implementation — Default prompt for implementing a GitHub issue
# Used by: Prompts::BuildForIssue, Activities::CreateAgentRunActivity,
#          PromptAssembly::Sections::IssueTask
# Safety rules are appended separately by the assembly/prompt builder paths.
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "coding.issue_implementation",
  name: "Issue Implementation",
  description: "Default prompt for implementing a GitHub issue. Includes task description and instructions. Safety rules are appended separately.",
  category: "coding",
  template: <<~'TEMPLATE',
    # Task

    You are working on the following GitHub issue:

    **{{title}}** (#{{issue_number}})

    {{body}}

    # Instructions

    1. Install dependencies (`bundle install`, `yarn install`, etc.)
    {{setup_database_instruction}}
    2. Analyze the issue and understand what needs to be done
    3. Make the necessary code changes
    4. Run lint and fix any violations: `{{lint_command}}`
    5. Run the test suite and fix any failures: `{{test_command}}`
    6. Commit your changes with a descriptive message

    **Important:** Git pre-commit hooks will automatically run lint and tests when you commit.
    If the commit is rejected, read the error output carefully, fix the issues, and commit again.
    Keep iterating until the commit succeeds. Do not leave uncommitted changes.
  TEMPLATE
  variables: [
    var.call("title", "Issue title"),
    var.call("issue_number", "GitHub issue number"),
    var.call("body", "Issue body/description"),
    var.call("test_command", "Test command for the project language", required: false),
    var.call("lint_command", "Lint command for the project language", required: false),
    var.call("setup_database_instruction", "Optional database setup line for projects with service containers", required: false)
  ]
)

# ----------------------------------------------------------------------------
# coding.pr_review_rebase — Instructions+rules shell for PR follow-up runs
# Used by: Prompts::BuildForPr (dynamic CI/review/conflict sections are
# composed in code and prepended to this rendered shell).
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "coding.pr_review_rebase",
  name: "PR Review & Rebase",
  description: "Instructions and rules section for an agent working on an existing pull request. Dynamic sections (task, conflicts, CI failures, code review, conversation) are composed in code by Prompts::BuildForPr and prepended to this rendered shell.",
  category: "coding",
  template: <<~'TEMPLATE',
    # Instructions

    Priority order:
    {{priority_list}}

    Steps:
    1. Install dependencies (`bundle install`, `yarn install`, etc.)
    {{setup_database_instruction}}
    2. Work through the priorities above in order
    3. Proactive scan: After making your changes, review the **entire diff** you are
       about to commit{{review_scan_instruction}}. Look for missing guard clauses,
       insufficient input validation, unhandled edge cases, missing tests, unclear
       naming, and style inconsistencies. Fix every issue you find — the goal is
       zero new review rounds for problems you could have caught yourself.
    4. Run lint and fix any violations: `{{lint_command}}`
    5. Run the test suite and fix any failures: `{{test_command}}`
    6. Commit your changes with a descriptive message

    **Important:** Git pre-commit hooks will automatically run lint and tests when you commit.
    If the commit is rejected, read the error output carefully, fix the issues, and commit again.
    Keep iterating until the commit succeeds. Do not leave uncommitted changes.

    {{already_addressed_instruction}}

    When you're done, commit all your changes. Do not push.

    # Rules — you MUST follow these

    - **Lint and tests MUST pass before every commit.** Do not commit code that fails lint or tests.
    - **Never use `--no-verify`** or any flag that skips git hooks.
    - **Never disable linters** (e.g. rubocop:disable, eslint-disable, noqa) to silence failures. Fix the code instead.
    - **Fix forward** — if a check fails, fix the underlying issue. Do not bypass the check.
    - Work within the existing codebase style and conventions
    - Do not modify unrelated files
    - Focus on completing the specific tasks listed above
  TEMPLATE
  variables: [
    var.call("priority_list", "Numbered priority list assembled from PR state"),
    var.call("setup_database_instruction", "Optional database setup line", required: false),
    var.call("review_scan_instruction", "Extra clause emphasizing same-class issues when reviewers flagged something", required: false),
    var.call("already_addressed_instruction", "Instruction to emit the already-addressed marker when all listed review threads are already fixed", required: false),
    var.call("lint_command", "Project lint command"),
    var.call("test_command", "Project test command")
  ]
)

# ----------------------------------------------------------------------------
# coding.lid_aware_section — LID workflow instructions for coding runs
# Used by: Lid::InjectIntoPrompt
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "coding.lid_aware_section",
  name: "LID-Aware Workflow Section",
  description: "Prompt fragment appended to create_pr and review runs when a project is configured for Linked-Intent Development.",
  category: "coding",
  template: <<~'TEMPLATE',
    ## LID-Aware Workflow

    This repository declares Linked-Intent Development mode: `{{lid_mode}}`.

    - Read the project's high-level design doc and the relevant LLDs/EARS specs for the area this issue or PR touches. The conventional LID paths are `docs/high-level-design.md` and `docs/intent/`, but they may vary by project — locate the actual design docs if the standard paths are absent.
    - Walk the arrow before changing code: confirm the EARS trace to the LLD and the LLD traces to the HLD. If intent changed, update the spec and design docs first, then cascade into tests and code.
    - When the run includes confirmed elicited intent from issue enhancement, materialize that intent into draft or updated LLD and EARS artifacts before or alongside code changes.
    - Work tests first. Add `@spec` annotations in tests citing the EARS IDs, then add matching `@spec` annotations at the implementation-graph entry points for the behavior you changed.
    - Run `{{coherence_check_command}}` for the structural checks before you finish. Treat failures as soft-blocks: fix forward, never skip hooks, and never use `--no-verify`.
    - Record LID phase progress in the PR description: which specs you touched, what tests-first evidence you added, and the coherence-check result.
    {{scope_instruction}}
  TEMPLATE
  variables: [
    var.call("lid_mode", "Detected Linked-Intent Development mode"),
    var.call("coherence_check_command", "Preferred project-local coherence check command, plus fallback image path"),
    var.call("scope_instruction", "Extra instruction for scoped LID mode", required: false)
  ]
)

# ----------------------------------------------------------------------------
# service_environment.* — Atomic service-environment guidance blocks
# Used by: Prompts::ServiceContainerSections
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "service_environment.setup.ruby_db",
  name: "Service Environment Setup (Ruby + DB)",
  description: "Database setup instruction for Ruby projects with a configured database service.",
  category: "coding",
  template: <<~'TEMPLATE',
       Run `bin/rails db:prepare` to set up the database (`DATABASE_URL` will be configured for you).
  TEMPLATE
  variables: []
)

upsert_global_prompt.call(
  slug: "service_environment.setup.framework_db",
  name: "Service Environment Setup (Framework + DB)",
  description: "Database setup instruction for non-Ruby projects with a configured database service.",
  category: "coding",
  template: <<~'TEMPLATE',
       A database service will be available via the `DATABASE_URL` environment variable. Use your framework's standard command to create and migrate the database schema.
  TEMPLATE
  variables: []
)

upsert_global_prompt.call(
  slug: "service_environment.setup.no_db",
  name: "Service Environment Setup (No DB)",
  description: "No-database setup warning for projects without a configured database service.",
  category: "coding",
  template: <<~'TEMPLATE',
       Do NOT run `bin/setup`, `db:prepare`, or `db:migrate` — no database is available in this environment.
  TEMPLATE
  variables: []
)

upsert_global_prompt.call(
  slug: "service_environment.available_services_intro",
  name: "Service Environment Available Services Intro",
  description: "Introductory sentence for the service availability section shown when service containers are configured.",
  category: "coding",
  template: <<~'TEMPLATE',
    The following services are configured for this project and will be available in the agent environment:
  TEMPLATE
  variables: []
)

upsert_global_prompt.call(
  slug: "service_environment.schema_workflow_ruby",
  name: "Service Environment Schema Workflow (Ruby)",
  description: "Ruby/Postgres schema workflow guidance shown when a project has a configured database service.",
  category: "coding",
  template: <<~'TEMPLATE',

    # Database Schema Workflow

    When you need a schema change:

    - Use `bin/rails generate migration <Name>` to create the migration file.
      Never write a migration file by hand.
    - Run `bin/rails db:migrate` so the change executes against Postgres and
      `db/schema.rb` is regenerated by Rails. Never edit `db/schema.rb` by hand
      to match a new migration — running the migration is what catches
      `strong_migrations` violations (unsafe index adds, blocking column
      rewrites, etc.) and keeps the schema dump in sync.
    - Make migrations safe to rerun after a partial failure. Use defensive
      guards such as `table_exists?`, `column_exists?`, and `index_exists?`
      where rerunning against a partially changed database could otherwise fail.
    - Commit the migration file and the regenerated `db/schema.rb` together.
  TEMPLATE
  variables: []
)

upsert_global_prompt.call(
  slug: "service_environment.environment_constraints_no_db",
  name: "Service Environment Constraints (No DB)",
  description: "Environment constraints guidance shown when no database service is available in the agent environment.",
  category: "coding",
  template: <<~'TEMPLATE',
    You are running in an isolated container WITHOUT database services.
    Do NOT attempt to install PostgreSQL, Redis, or any other infrastructure service.
    Do NOT run `bin/setup`, `bin/rails db:prepare`, `bin/rails db:migrate`, or `initdb`.

    If a task requires database access and none is available:
    - Implement the code changes and write tests that use mocks, factories, or other
      techniques that do not require a real database connection.
    - Do NOT attempt to start or provision your own database server.
    - If the default test command or pre-commit hook fails because it cannot reach the
      database, run whatever subset of tests can pass without a database and clearly
      explain in your final answer which tests could not be run due to missing services.
  TEMPLATE
  variables: []
)

# ----------------------------------------------------------------------------
# ci.failure_guidance — Data-driven CI failure debugging guidance
# Used by: Prompts::BuildForPr (rendered and injected into CI failures section)
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "ci.failure_guidance",
  name: "CI Failure Guidance",
  description: "Provides strategy for debugging CI failures. Rendered with failure_types and workflow_content, then injected into the PR follow-up prompt. A/B testable and evolvable by the meta-agent.",
  category: "coding",
  template: <<~'TEMPLATE',
    ## Debugging Strategy

    First, classify the failure:

    - **Code error** (syntax errors, test assertions, logic bugs): Fix the
      application code. Reproduce locally using the test command.
    - **Configuration error** (wrong database config, missing ENV vars in
      `config/`): Fix the configuration file. Compare how the config is used
      in CI vs locally.
    - **CI infrastructure error** (database not created, service unreachable,
      setup step missing `RAILS_ENV`): Fix the CI workflow file in
      `.github/workflows/`. These errors often occur because a setup step
      runs in a different environment (e.g., `development` mode) than the
      test step (e.g., `test` mode).

    {{failure_type_hints}}

    {{workflow_content_section}}

    **Important:** CI infrastructure errors cannot be reproduced locally — the
    agent container environment differs from the CI runner environment. Fix the
    workflow file or configuration directly, commit the change, and do not
    attempt local reproduction of the infrastructure issue.
  TEMPLATE
  variables: [
    var.call("failure_type_hints", "Targeted hints based on classified failure types", required: false),
    var.call("workflow_content_section", "CI workflow YAML files when available", required: false)
  ]
)

# ----------------------------------------------------------------------------
# diagnostics.agent_run_failure — Failure diagnosis for failed agent runs
# Used by: AgentRuns::DiagnoseError
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "diagnostics.agent_run_failure",
  name: "Agent Run Failure Diagnosis",
  description: "Analyzes a failed agent run's error and recent logs and produces a Markdown diagnosis (summary, root cause, suggested fix).",
  category: "review",
  template: <<~'TEMPLATE',
    You are diagnosing a failed agent run. Analyze the error and logs below, then provide:
    1. A brief summary of what went wrong
    2. The root cause of the failure
    3. A suggested fix or workaround

    Be concise and actionable. Format your response in Markdown.

    ## Context
    - Agent type: {{agent_type}}
    - Goal: {{goal}}
    - Task: {{task}}
    - Status: {{status}}
    - Duration: {{duration}}s

    ## Error Message
    ```
    {{error_text}}
    ```

    ## Recent Logs
    ```
    {{logs_text}}
    ```
  TEMPLATE
  variables: [
    var.call("agent_type", "Agent type (e.g. claude_code)"),
    var.call("goal", "Agent run goal"),
    var.call("task", "Linked issue title or custom prompt"),
    var.call("status", "Final status of the agent run"),
    var.call("duration", "Duration in seconds"),
    var.call("error_text", "Redacted, truncated error message"),
    var.call("logs_text", "Redacted, truncated tail of agent run logs")
  ]
)

# ----------------------------------------------------------------------------
# planning.decompose_feature — Break a feature into independently shippable tasks
# Used by: Activities::DecomposeFeatureActivity
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "planning.decompose_feature",
  name: "Feature Decomposition",
  description: "Decomposes a feature request into independently implementable sub-tasks with dependencies and parallel groups.",
  category: "planning",
  template: <<~'TEMPLATE',
    You are a software architect. Analyze the following feature request and decompose it into smaller, independently-implementable sub-tasks.

    ## Feature Request
    **Title:** {{title}}
    **Description:**
    {{body}}

    {{knowledge_section}}

    ## Instructions
    - Each sub-task should be independently implementable and testable
    - Order tasks by dependency (tasks that others depend on come first)
    - Mark tasks that can be worked on in parallel (no dependencies between them)
    - If this is a simple feature that doesn't need decomposition, return a single task
    - Keep task descriptions clear and actionable
    - Include acceptance criteria for each task
    - Maximum {{max_tasks}} tasks

    ## Output Format
    Respond with ONLY a JSON array. Each element must have these fields:
    - "title": concise task title (string)
    - "description": detailed description with acceptance criteria (string)
    - "dependencies": array of task indices (0-based) this task depends on (array of integers)
    - "parallel_group": integer grouping tasks that can run in parallel (tasks with the same group number have no dependencies on each other)

    Example:
    [
      {"title": "Add database migration for X", "description": "Create migration to add...", "dependencies": [], "parallel_group": 0},
      {"title": "Implement model for X", "description": "Create ActiveRecord model...", "dependencies": [0], "parallel_group": 1},
      {"title": "Add API endpoint for X", "description": "Create controller action...", "dependencies": [1], "parallel_group": 2}
    ]
  TEMPLATE
  variables: [
    var.call("title", "Issue title"),
    var.call("body", "Issue body, truncated"),
    var.call("knowledge_section", "Optional ## Codebase Context block from semantic search", required: false),
    var.call("max_tasks", "Maximum number of tasks to emit")
  ]
)

# ----------------------------------------------------------------------------
# planning.model_selection — Pick the best LLM for a development task
# Used by: Models::MetaAgentSelector
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "planning.model_selection",
  name: "Meta-Agent Model Selection",
  description: "Asks an LLM to choose the best available model for a development task based on complexity, cost, and budget context.",
  category: "planning",
  template: <<~'TEMPLATE',
    Select the best LLM model for this development task.

    ## Task
    Goal: {{goal}}
    {{task_details}}

    ## Project
    Repository: {{repository}}
    {{budget_context}}

    ## Available Models
    {{candidates}}

    ## Instructions
    Consider task complexity, reasoning requirements, cost-effectiveness, and any budget constraints.
    Simple tasks (typo fixes, small edits) should use cheaper models.
    Complex tasks (architecture, multi-file refactors) need the most capable models.
    If budget is limited, prefer cost-effective models unless the task clearly requires high capability.

    Respond with ONLY a JSON object:
    {"model": "model-id", "reasoning": "brief explanation", "complexity_score": 5.0}

    complexity_score must be a number from 1.0 (trivial) to 10.0 (extremely complex).
  TEMPLATE
  variables: [
    var.call("goal", "Agent run goal"),
    var.call("task_details", "Title + truncated body of the linked issue, or 'No linked issue'"),
    var.call("repository", "Project full_name (owner/repo)"),
    var.call("budget_context", "Optional budget summary line", required: false),
    var.call("candidates", "Newline-separated list of available models with costs")
  ]
)

# ----------------------------------------------------------------------------
# evolution.mutate_prompt — Generate improved variants of an existing prompt
# Used by: PromptEvolution::Mutate
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "evolution.mutate_prompt",
  name: "Prompt Mutation",
  description: "Asks an LLM to generate N improved variants of a prompt template using configurable strategies (refinement, restructuring, simplification, expansion).",
  category: "planning",
  template: <<~'TEMPLATE',
    You are a prompt engineering expert. Analyze the following prompt and its performance data, then generate {{mutation_count}} improved variant(s).

    ## Current Prompt Template
    ```
    {{current_template}}
    ```

    {{variables_section}}
    {{system_prompt_section}}
    {{performance_section}}
    {{sample_outputs_section}}
    {{strategies_section}}

    ## Instructions
    Generate exactly {{mutation_count}} improved prompt variant(s). Each variant must:
    {{variables_preservation_instruction}}- Be a complete, standalone prompt template (not a diff or partial edit)
    - Apply one of the requested strategies: {{strategies_csv}}
    - Address specific weaknesses identified in the performance data

    Respond with ONLY valid JSON in this exact format (no markdown fences, no explanation):
    {"mutations":[{"template":"improved prompt text","strategy":"one of {{strategies_pipe}}","reasoning":"what problem this addresses","expected_improvement":"why this should perform better"}]}
  TEMPLATE
  variables: [
    var.call("mutation_count", "Number of variants to generate"),
    var.call("current_template", "Redacted current prompt template"),
    var.call("variables_section", "Optional ## Template Variables block", required: false),
    var.call("system_prompt_section", "Optional ## System Prompt block", required: false),
    var.call("performance_section", "## Performance Data block"),
    var.call("sample_outputs_section", "Optional ## Sample Outputs block", required: false),
    var.call("strategies_section", "## Mutation Strategies block"),
    var.call("variables_preservation_instruction", "Instruction line about preserving {{var}} placeholders", required: false),
    var.call("strategies_csv", "Comma-separated strategies"),
    var.call("strategies_pipe", "Slash-separated strategies for the JSON example")
  ]
)

# ----------------------------------------------------------------------------
# style.extract_guide — Extract a coding style guide from code samples
# Used by: StyleGuides::Extract
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "style.extract_guide",
  name: "Style Guide Extraction",
  description: "Extracts coding style conventions from a set of representative code samples in a given language. Code samples are appended after the rendered prompt.",
  category: "review",
  template: <<~'TEMPLATE',
    You are a senior software engineer. Analyze the following code samples from a {{language}} codebase and extract the coding style conventions you observe.

    Output a concise style guide covering:
    - Naming conventions (variables, methods, classes, files)
    - Formatting patterns (indentation, line length, spacing)
    - Code organization (module structure, imports, file layout)
    - Common patterns and idioms used
    - Error handling conventions
    - Testing patterns (if test files are included)

    Rules:
    - Only document conventions actually present in the code — do not invent rules
    - Use terse bullet points grouped by category
    - Include short code snippets only when they clarify a pattern
    - Output plain text with markdown formatting
    - Keep the guide under 3000 words

    Code samples:
  TEMPLATE
  variables: [
    var.call("language", "Programming language (e.g. ruby, typescript)")
  ]
)

# ----------------------------------------------------------------------------
# style.compress_guide — Compress a verbose style guide into LLM-friendly form
# Used by: StyleGuides::Compress
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "style.compress_guide",
  name: "Style Guide Compression",
  description: "Compresses a raw style guide into a terse, LLM-friendly format. The raw guide content is appended after the rendered prompt.",
  category: "review",
  template: <<~'TEMPLATE',
    You are a technical writing assistant. Compress the following coding style guide into a concise, LLM-friendly format.

    Rules:
    - Keep all concrete rules (naming conventions, formatting, patterns to use/avoid)
    - Remove verbose explanations, examples that restate the rule, and motivational text
    - Use terse bullet points grouped by category
    - Preserve code snippets only when they define a pattern (e.g. preferred import style)
    - Target roughly 30-50% of the original length
    - Output plain text with markdown formatting

    Style guide to compress:
  TEMPLATE
  variables: []
)

# ----------------------------------------------------------------------------
# generation.issue_title — Generate a concise issue title from agent output
# Used by: Llm::GenerateIssueTitle
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "generation.issue_title",
  name: "Issue Title Generation",
  description: "Generates a single concise GitHub issue title from agent output. Returns the title text only, no quotes or prefix.",
  category: "review",
  template: <<~'TEMPLATE',
    Generate a concise GitHub issue title for the following agent output. Respond with ONLY the title text — no quotes, no prefix, no explanation. Keep it under {{max_title_length}} characters.

    {{summary}}
  TEMPLATE
  variables: [
    var.call("max_title_length", "Maximum title length in characters"),
    var.call("summary", "Truncated agent output to summarize")
  ]
)

# ----------------------------------------------------------------------------
# generation.pr_description — Generate a structured PR description
# Used by: Llm::GeneratePrDescription
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "generation.pr_description",
  name: "PR Description Generation",
  description: "Generates a structured PR description that leads with 'why', summarizes scope, and surfaces design decisions. Used after an agent run completes.",
  category: "review",
  template: <<~'TEMPLATE',
    You are writing a pull request description for a code change. Write a clear, well-structured PR description following these rules:

    1. **Lead with "why"** — the first sentence must frame the goal and expected outcome, not implementation details.
    2. **Summarize the full scope** — describe all changes organized by concern (e.g., database, models, services, UI, infrastructure).
    3. **Surface design decisions** — call out important trade-offs, constraints, or choices a reviewer should understand.
    4. **Scale depth to complexity** — keep it concise for small changes; use structured sections for large cross-cutting changes.
    5. **Mention operational concerns** — note any deployment steps, migration notes, or infrastructure changes if relevant.
    6. **Include visuals for UI changes** — if the agent output indicates user-facing UI changes, add a ## Screenshots section with a placeholder reminding the author to attach before/after screenshots.

    Use markdown formatting. Start with a ## Summary section containing 1-3 sentences explaining the purpose. Then add a ## Changes section with a bulleted breakdown organized by concern. If there are notable design decisions, add a ## Design Decisions section. Do NOT include a test plan section.

    Respond with ONLY the PR description markdown — no preamble, no wrapping quotes, no explanation.

    ## Issue Context
    Title: {{issue_title}}
    Body:
    {{issue_body}}

    ## Agent Output
    {{agent_summary}}
  TEMPLATE
  variables: [
    var.call("issue_title", "Linked issue title or 'N/A'"),
    var.call("issue_body", "Truncated linked issue body or 'N/A'"),
    var.call("agent_summary", "Truncated agent output")
  ]
)

# ----------------------------------------------------------------------------
# knowledge.draft_decision — Draft an ADR-lite decision record from an agent run
# Used by: Knowledge::Decisions::Draft
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "knowledge.draft_decision",
  name: "Decision Record Drafting",
  description: "Drafts an ADR-lite decision record (title, summary, context, decision, consequences, tags) from a completed agent run's PR changes.",
  category: "review",
  template: <<~'TEMPLATE',
    You are drafting a Decision Record (ADR-lite) for a code change.

    Given the following context about an agent run that created a pull request,
    produce a structured decision record in JSON format with these fields:
    - title: A concise title for the decision (max 100 chars)
    - summary: 1-3 sentence summary of what was decided
    - context: Background/situation that led to this decision
    - decision: What was decided and implemented
    - consequences: Expected outcomes and trade-offs
    - tags: Array of relevant tags (e.g., ["auth", "api", "performance"])

    Respond with ONLY valid JSON, no markdown fences or extra text.

    ## Agent Run Context
    Issue: {{issue_title}}
    PR Changes Summary:
    {{changes_summary}}
  TEMPLATE
  variables: [
    var.call("issue_title", "Linked issue title or 'N/A'"),
    var.call("changes_summary", "Truncated PR changes summary")
  ]
)

# ----------------------------------------------------------------------------
# goal.create_github_issue — Augment a base prompt for the create-issue goal
# Used by: Activities::RunAgentActivity#augment_prompt_for_issue_goal
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: Prompts::GoalCreateGithubIssue::PROMPT_SLUG,
  name: "Goal: Create GitHub Issue",
  description: "Augments a base prompt with instructions to create a GitHub issue via the API proxy. Used when an agent run's goal is to file an issue rather than open a PR.",
  category: "planning",
  template: Prompts::GoalCreateGithubIssue::TEMPLATE,
  variables: Prompts::GoalCreateGithubIssue::VARIABLES
)

# ----------------------------------------------------------------------------
# goal.review_pull_request — Augment a base prompt for the review-PR goal
# Used by: Activities::RunAgentActivity#augment_prompt_for_review_goal
#
# IMPORTANT: This template instructs the agent to post a clean-review body
# starting with the EXACT phrase "Generated no new comments." which matches
# ScanPaidPrsActivity::REVIEW_BOT_CLEAN_PATTERN. If that matcher pattern
# changes, update this template AND the FALLBACK constant in
# Activities::RunAgentActivity together.
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "goal.review_pull_request",
  name: "Goal: Review Pull Request",
  description: "Augments a base prompt with instructions to review an existing PR. Forbids praise-only inline comments and requires the clean-PR signal phrase Paid uses to stop the review loop.",
  category: "review",
  template: <<~'TEMPLATE',
    {{base_prompt}}

    ---
    IMPORTANT: Your goal is to REVIEW A PULL REQUEST, not to write code, create issues, or create PRs.

    Review PR #{{pr_number}} in {{repo}}. Examine the code changes and post a review on the PR.
    Your review will be posted to GitHub under the `paid-code-reviewer[bot]`
    account, so write in a direct review voice and do not mention that you
    are unable to post as a bot.

    You have access to the repository code (already cloned). To examine the code changes, either:
    - Use the GitHub API (via the proxy) to retrieve the PR's `/pulls/{{pr_number}}/files` patches and review those diffs; or
    - From the cloned repo, run an explicit diff against the PR base, for example:
      `git fetch origin` then `git diff "$(git merge-base HEAD origin/main)"...HEAD`
      (replace `main` with the PR's actual base branch if different).
    You also have access to the GitHub API via a proxy for posting review comments.

    You can search the project's knowledge base to look up existing code,
    symbols, routes, and patterns before deciding whether a finding is valid:

    ```bash
    curl -s --connect-timeout 10 --max-time 30 "$KNOWLEDGE_SEARCH_URL?q=review+pattern" \
      -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
      -H "X-Proxy-Token: $PROXY_TOKEN"
    ```

    Use this when the PR diff or linked issue raises a question that existing
    code patterns can answer. Do not ask for clarification or report a finding
    until you have checked whether the knowledge base answers it.

    You may run targeted validation when it is useful for review confidence.
    Before running Ruby/Rails commands such as `bin/rspec`, run
    `bundle check || BUNDLE_FROZEN=true bundle install --jobs 4 --retry 3`
    so the fresh review checkout has the bundled gems it needs without
    changing the lockfile. If dependency installation or test execution still
    fails because of missing network access, services, or environment
    constraints, mention that specific blocker in the review body.

    Review the code for:
    1. **Performance** — inefficient algorithms, N+1 queries, unnecessary allocations, missing caching
    2. **Security** — SQL injection, XSS, insecure deserialization, secrets in code
    3. **Best practices** — language/framework idioms, error handling, naming
    4. **Project code style** — adherence to existing conventions, indentation, file organization
    5. **Scope violations** — changes unrelated to the linked issue, unnecessary refactoring, feature creep
    6. **Issue linkage** — verify the PR actually addresses the issue it claims to fix

    # Comment policy — read carefully

    Inline comments are reserved **exclusively for actionable changes**: security,
    correctness, performance, scope, or style problems that require the author to
    edit code. Do **not** post praise-only comments, "looks good" notes, "nice
    refactor" remarks, or any inline comment that does not request a concrete
    change. If you have nothing actionable to say about a hunk, do not comment on it.

    A clean PR with zero issues is a valid and expected outcome. Do not invent
    nitpicks to justify having posted a review.

    Use GitHub's suggestion block syntax for concrete fixes:
    ````
    ```suggestion
    corrected code here
    ```
    ````

    MANDATORY: When you find actionable issues (Case A), each issue MUST include an
    inline comment in the "comments" array with a specific "path" and "line" number.
    A review body describing problems WITHOUT corresponding inline comments is
    incomplete. If you cannot identify specific file paths and line numbers, do not
    include that issue in the review.

    Post your review using the GitHub API proxy.

    IMPORTANT: Do NOT pass the review JSON inline with a single-quoted `-d '...'`.
    Review bodies and inline comments contain markdown, suggestion blocks, newlines,
    and apostrophes — inlining that payload breaks shell quoting and produces
    malformed JSON (invalid control characters inside strings) that Rails rejects
    before the request ever reaches GitHub. Always write the review JSON to a
    temporary file and submit it with `--data-binary @file`.

    ```bash
    # Get PR details (metadata and links)
    curl -s --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}" \
      -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
      -H "X-Proxy-Token: $PROXY_TOKEN"

    # Get PR files
    curl -s --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/files" \
      -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
      -H "X-Proxy-Token: $PROXY_TOKEN"

    # Case A — actionable issues found: post a review with inline comments.
    # MANDATORY: When you find actionable issues, each issue MUST include an
    # inline comment in the "comments" array with a specific "path" and
    # "line" number. A review body that describes problems without matching
    # inline comments is incomplete. If you cannot identify a specific file
    # path and line number for an issue, do not include that issue in the review.
    # Note: "side" must be "RIGHT" (new code) or "LEFT" (deleted code).
    tmpfile=$(mktemp)
    cat > "$tmpfile" <<'REVIEW_JSON'
    {
      "body": "Overall summary of the actionable issues found",
      "event": "COMMENT",
      "comments": [
        {
          "path": "file.rb",
          "line": 10,
          "side": "RIGHT",
          "body": "Actionable change request on this line"
        }
      ]
    }
    REVIEW_JSON
    curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/reviews" \
      -H "Content-Type: application/json" \
      -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
      -H "X-Proxy-Token: $PROXY_TOKEN" \
      --data-binary @"$tmpfile"
    rm -f "$tmpfile"

    # Case B — clean PR, no actionable issues: post a single review with an EMPTY
    # comments array and a body that begins with the EXACT phrase
    # "Generated no new comments." Include the exact HTML marker
    # "<!-- paid-review-clean -->" somewhere in the body. These are the
    # signals Paid uses to mark the review as clean and stop the review loop.
    # Do NOT paraphrase either signal.
    tmpfile=$(mktemp)
    cat > "$tmpfile" <<'REVIEW_JSON'
    {
      "body": "Generated no new comments. The PR looks ready as-is. <!-- paid-review-clean -->",
      "event": "COMMENT",
      "comments": []
    }
    REVIEW_JSON
    curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/reviews" \
      -H "Content-Type: application/json" \
      -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
      -H "X-Proxy-Token: $PROXY_TOKEN" \
      --data-binary @"$tmpfile"
    rm -f "$tmpfile"
    ```

    If you ever need to send any other JSON payload to the proxy (for example a
    follow-up issue comment), apply the same pattern: write the body to a temp
    file and submit with `--data-binary @file`. Never inline JSON with `-d '...'`.

    # Pre-submission verification

    Before submitting your review, verify your JSON payload:
    - Case A: "comments" array is NON-EMPTY, each entry has "path", "line", and "body"
    - Case B: body starts with EXACTLY "Generated no new comments." and "comments" is []

    CRITICAL: Always use `"event": "COMMENT"` — never use `"event":
    "REQUEST_CHANGES"` or `"event": "APPROVE"`. Change requests are
    expressed through inline comments in the "comments" array, not
    through the review event. Using REQUEST_CHANGES blocks PR merging
    and will be automatically dismissed.

    IMPORTANT: You MUST post exactly one PR review via the
    `/pulls/{{pr_number}}/reviews` endpoint — either Case A (with inline
    actionable comments) or Case B (clean review). This is how your review is
    tracked as complete. Standalone PR comments via
    `/issues/{{pr_number}}/comments` do NOT satisfy the review requirement.

    Available endpoints:
    - GET  $GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}} — get PR details
    - GET  $GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/files — list changed files
    - POST $GITHUB_API_URL/repos/{{repo}}/pulls/{{pr_number}}/reviews — create review (REQUIRED, exactly once)
    - GET  $GITHUB_API_URL/repos/{{repo}}/issues/{number} — get linked issue details

    Do NOT push code, create issues, or create new pull requests. Only post the review on PR #{{pr_number}}.
  TEMPLATE
  variables: [
    var.call("base_prompt", "The base prompt this augmentation extends"),
    var.call("repo", "Repository full_name (owner/repo)"),
    var.call("pr_number", "Pull request number")
  ]
)

# ----------------------------------------------------------------------------
# goal.enhance_issue — Augment a base prompt for the enhance-issue goal
# Used by: Activities::RunAgentActivity#augment_prompt_for_enhance_issue_goal
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "goal.enhance_issue",
  name: "Goal: Enhance Issue",
  description: "Augments a base prompt with instructions to enhance an existing GitHub issue by adding implementation context or asking clarifying questions.",
  category: "planning",
  template: <<~'TEMPLATE',
    {{base_prompt}}

    ---
    IMPORTANT: Your goal is to ENHANCE AN EXISTING ISSUE by adding context or asking clarifying questions.
    Do NOT write code, create PRs, create new issues, push commits, or post GitHub comments.

    This run is read-only: do NOT modify files in /workspace, commit, push, create a PR,
    or mutate GitHub. The workflow discards workspace modifications and posts the validated
    enhancement comment itself. You can explore and read the repo freely.
    State directories (under /home/agent/) are writable for scratch/tooling needs.

    Read issue #{{issue_number}} in {{repo}}. Trusted collaborator comments are already included in
    the base prompt; do not fetch raw issue comments. Explore the repository
    to self-answer codebase-determinable questions (existing models, platform targets, patterns, etc.)
    before asking the human. Only ask about genuine product, scope, or intent ambiguities.

    You can search the project's knowledge base to look up existing code,
    symbols, routes, and patterns before asking questions:

    ```bash
    curl -s --connect-timeout 10 --max-time 30 "$KNOWLEDGE_SEARCH_URL?q=sortable+column+dashboard" \
      -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
      -H "X-Proxy-Token: $PROXY_TOKEN"
    ```

    Use the GitHub API proxy only to read issue details:

    ```bash
    curl -s --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/issues/{{issue_number}}" \
      -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
      -H "X-Proxy-Token: $PROXY_TOKEN"
    ```

    When you are finished, print your result on stdout wrapped between
    delimiter lines (exactly `paid-enhance-issue-output` on its own line,
    before and after the JSON). Print nothing else between the markers:

    paid-enhance-issue-output
    {
      "sufficient_context": true or false,
      "comment_body": "Markdown comment with implementation context or clarifying questions"
    }
    paid-enhance-issue-output

    If sufficient_context is true, the comment_body should include:
    ## Implementation context
    ### Relevant files and symbols
    - ...
    ### Architecture notes
    - ...
    ### Suggested approach
    - ...

    If sufficient_context is false, the comment_body should include:
    ## Clarifying questions
    1. ...
    ## Current context
    - ...
  TEMPLATE
  variables: [
    var.call("base_prompt", "The base prompt this augmentation extends"),
    var.call("repo", "Repository full_name (owner/repo)"),
    var.call("issue_number", "GitHub issue number")
  ]
)

# ----------------------------------------------------------------------------
# lid.planning — LID brownfield analysis + Planning PR bootstrap
# Used by: Prompts::BuildForLidPlanning
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "lid.planning",
  name: "LID Planning — Brownfield Analysis",
  description: "Bootstraps a Linked-Intent Development design tree via brownfield analysis. Reads the repo and any named plan docs, produces docs-only HLD/LLD/EARS artifacts, adds the ## LID block to AGENTS.md, creates docs/arrows/index.yaml, and opens a Planning PR with an inference checklist.",
  category: "planning",
  template: Prompts::BuildForLidPlanning::FALLBACK_PROMPT,
  variables: [
    var.call("project_name", "Human-readable project name"),
    var.call("full_name", "Repository full_name (owner/repo)")
  ]
)

# ----------------------------------------------------------------------------
# coding.create_feature_prompt — `create_feature` agent run prompt
# Used by: Prompts::BuildForCreateFeature
# ----------------------------------------------------------------------------
upsert_global_prompt.call(
  slug: "coding.create_feature_prompt",
  name: "Create Feature — RDR + Issue Tree",
  description: "Instructions for a `create_feature` agent run: research the repo, write an RDR under docs/rdrs/, update docs/rdrs/README.md, open a docs-only PR, and decompose the RDR's Implementation Plan into a tree of linked GitHub issues. Inputs are sourced from the feature brief on AgentRun#external_metadata.",
  category: "coding",
  template: Prompts::BuildForCreateFeature::FALLBACK_PROMPT,
  variables: [
    var.call("project_name", "Human-readable project name"),
    var.call("full_name", "Repository full_name (owner/repo)"),
    var.call("feature_brief", "Structured feature brief (title, problem, desired behavior, constraints, rejected alternatives, scope, done criteria, lid_requested, target_rdr_number)"),
    var.call("lid_mode", "Project LID mode when enabled", required: false),
    var.call("lid_section", "Rendered LID instructions when the project has or requested LID", required: false)
  ]
)
