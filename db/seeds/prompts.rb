# frozen_string_literal: true

# Seed default prompts for coding tasks.
# Migrates logic from Prompts::BuildForIssue into the database.

CODING_ISSUE_TEMPLATE = <<~'TEMPLATE'
  # Task

  You are working on the following GitHub issue:

  **{{title}}** (#{{issue_number}})

  {{body}}

  # Instructions

  1. Analyze the issue and understand what needs to be done
  2. Make the necessary code changes
  3. Ensure tests pass (run `{{test_command}}` if available)
  4. Ensure linting passes (run `{{lint_command}}` if available)
  5. Commit your changes with a descriptive message

  # Important

  - Work within the existing codebase style and conventions
  - Do not modify unrelated files
  - If you're unsure about something, leave a comment in the code
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

if prompt.new_record? || prompt.current_version.nil?
  prompt.save!
  prompt.create_version!(
    template: CODING_ISSUE_TEMPLATE,
    variables: CODING_ISSUE_VARIABLES,
    created_by: "seed",
    change_notes: "Initial version migrated from Prompts::BuildForIssue"
  )

  Rails.logger.info(message: "seeds.created_prompt", slug: "coding.issue_implementation")
end
