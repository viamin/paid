# frozen_string_literal: true

# @spec AUTO-MERGE-009
class SyncIssueImplementationPromptHoldScope < ActiveRecord::Migration[8.1]
  CHANGE_NOTES = "Limit agent review holds to explicit human-only decisions (#4974)"
  PROMPT_SLUG = "coding.issue_implementation"
  TEMPLATE = PromptAssembly::Sections::IssueTask::FALLBACK_PROMPT
  VARIABLES = [
    { "name" => "title", "required" => true, "description" => "Issue title" },
    { "name" => "issue_number", "required" => true, "description" => "GitHub issue number" },
    { "name" => "body", "required" => true, "description" => "Issue body/description" },
    { "name" => "test_command", "required" => false, "description" => "Test command for the project language" },
    { "name" => "lint_command", "required" => false, "description" => "Lint command for the project language" },
    { "name" => "setup_database_instruction", "required" => false, "description" => "Optional database setup line for projects with service containers" },
    { "name" => "commit_message_guidance", "required" => false, "description" => "Quiet-mode commit message guidance shown only when the project has quiet mode enabled (#4232)" },
    { "name" => "merge_delegation_note", "required" => false, "description" => "Effective merge-policy delegation statement for review-hold decisions (#4974)" }
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
