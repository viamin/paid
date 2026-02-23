# frozen_string_literal: true

# Seed default prompts for coding tasks.
# Migrates logic from Prompts::BuildForIssue into the database.

CODING_ISSUE_TEMPLATE = <<~'TEMPLATE'
  # Task

  You are working on the following GitHub issue:

  **{{title}}** (#{{issue_number}})

  {{body}}

  # Instructions

  1. Set up the project first — install dependencies (`bundle install`, `npm install`, etc.)
  2. Analyze the issue and understand what needs to be done
  3. Make the necessary code changes
  4. Run lint and fix any violations: `{{lint_command}}`
  5. Run the test suite and fix any failures: `{{test_command}}`
  6. Commit your changes with a descriptive message

  **Important:** Git pre-commit hooks will automatically run lint and tests when you commit.
  If the commit is rejected, read the error output carefully, fix the issues, and commit again.
  Keep iterating until the commit succeeds. Do not leave uncommitted changes.

  # Rules — you MUST follow these

  - **Lint and tests MUST pass before every commit.** Do not commit code that fails lint or tests.
  - **Never use `--no-verify`** or any flag that skips git hooks.
  - **Never disable linters** (e.g. rubocop:disable, eslint-disable, noqa) to silence failures. Fix the code instead.
  - **Fix forward** — if a check fails, fix the underlying issue. Do not bypass the check.
  - Work within the existing codebase style and conventions
  - Do not modify unrelated files
  - Focus on completing the specific task in the issue

  When you're done, commit all your changes. Do not push.
TEMPLATE

CODING_ISSUE_VARIABLES = [
  { "name" => "title", "required" => true, "description" => "Issue title" },
  { "name" => "issue_number", "required" => true, "description" => "GitHub issue number" },
  { "name" => "body", "required" => true, "description" => "Issue body/description" },
  { "name" => "test_command", "required" => false, "description" => "Test command for the project language" },
  { "name" => "lint_command", "required" => false, "description" => "Lint command for the project language" }
].freeze

prompt = Prompt.find_or_initialize_by(slug: "coding.issue_implementation", account_id: nil, project_id: nil)
prompt.assign_attributes(
  name: "Issue Implementation",
  description: "Default prompt for implementing a GitHub issue. Includes task description, instructions, and coding guidelines.",
  category: "coding",
  active: true
)

prompt.save!

current = prompt.current_version

if current.nil? ||
   current.template != CODING_ISSUE_TEMPLATE ||
   current.variables != CODING_ISSUE_VARIABLES
  change_notes = if current.nil?
    "Initial version migrated from Prompts::BuildForIssue"
  else
    "Updated from seeds: template and/or variables changed"
  end

  prompt.create_version!(
    template: CODING_ISSUE_TEMPLATE,
    variables: CODING_ISSUE_VARIABLES,
    created_by: "seed",
    change_notes: change_notes
  )

  Rails.logger.info(message: "seeds.created_prompt", slug: "coding.issue_implementation")
end
