# frozen_string_literal: true

class SyncIssueImplementationPromptRemoveSafetyRules < ActiveRecord::Migration[8.1]
  CHANGE_NOTES = "Remove embedded safety rules from issue implementation template; safety rules are now appended by a separate section"
  PROMPT_SLUG = "coding.issue_implementation"
  VARIABLES = [
    {
      "name" => "title",
      "required" => true,
      "description" => "Issue title"
    },
    {
      "name" => "issue_number",
      "required" => true,
      "description" => "GitHub issue number"
    },
    {
      "name" => "body",
      "required" => true,
      "description" => "Issue body/description"
    },
    {
      "name" => "test_command",
      "required" => false,
      "description" => "Test command for the project language"
    },
    {
      "name" => "lint_command",
      "required" => false,
      "description" => "Lint command for the project language"
    },
    {
      "name" => "setup_database_instruction",
      "required" => false,
      "description" => "Optional database setup line for projects with service containers"
    }
  ].freeze
  TEMPLATE = <<~'TEMPLATE'
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

  # Global prompts carry no account_id, so the tenant_isolation_update policy on
  # `prompts` never admits them. Prompt#create_version! locks the row before
  # promoting the new version, and PostgreSQL evaluates SELECT ... FOR UPDATE
  # against that write policy — without system access the lock finds no row.
  #
  # @spec POSTGRESQL-PERSISTENCE-008
  def up
    TenantContext.with_system_access do
      prompt = Prompt.global.find_by(slug: PROMPT_SLUG)
      next unless prompt
      next if synced?(prompt.current_version)

      prompt.create_version!(
        template: TEMPLATE,
        variables: VARIABLES,
        created_by: "migration",
        change_notes: CHANGE_NOTES
      )
    end
  end

  def down
  end

  private

  def normalize(template)
    template.to_s.strip
  end

  def synced?(version)
    return false unless version

    normalize(version.template) == normalize(TEMPLATE) &&
      version.variables == VARIABLES
  end
end
