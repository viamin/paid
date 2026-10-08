# @spec AUTO-MERGE-009
class SyncIssueImplementationPromptHoldForReview < ActiveRecord::Migration[8.1]
  CHANGE_NOTES = "Tell issue implementation runs to use the structured paid-hold-review label (#4181)"
  PROMPT_SLUG = "coding.issue_implementation"
  TEMPLATE = PromptAssembly::Sections::IssueTask::FALLBACK_PROMPT
  VARIABLES = [
    { "name" => "title", "required" => true, "description" => "Issue title" },
    { "name" => "issue_number", "required" => true, "description" => "GitHub issue number" },
    { "name" => "body", "required" => true, "description" => "Issue body/description" },
    { "name" => "test_command", "required" => false, "description" => "Test command for the project language" },
    { "name" => "lint_command", "required" => false, "description" => "Lint command for the project language" },
    { "name" => "setup_database_instruction", "required" => false, "description" => "Optional database setup line for projects with service containers" }
  ].freeze

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

  def synced?(version)
    return false unless version

    version.template.to_s.strip == TEMPLATE.strip && version.variables == VARIABLES
  end
end
