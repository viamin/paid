# frozen_string_literal: true

# @spec ISSUE-ENHANCEMENT-001
class SyncEnhanceIssuePromptSimplifiedEnglish < ActiveRecord::Migration[8.1]
  CHANGE_NOTES = "Require simplified technical English in enhance_issue comments and clarifying questions"
  PROMPT_SLUG = "goal.enhance_issue"
  VARIABLES = [
    { "name" => "base_prompt", "required" => true, "description" => "The base prompt this augmentation extends" },
    { "name" => "repo", "required" => true, "description" => "Repository full_name (owner/repo)" },
    { "name" => "issue_number", "required" => true, "description" => "GitHub issue number" }
  ].freeze

  def up
    TenantContext.with_system_access do
      prompt = Prompt.global.find_by(slug: PROMPT_SLUG)
      next unless prompt
      next if synced?(prompt.current_version)

      prompt.create_version!(
        template: Activities::RunAgentActivity::FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT,
        variables: VARIABLES,
        created_by: "migration",
        change_notes: CHANGE_NOTES
      )
    end
  end

  def down; end

  private

  def synced?(version)
    return false unless version

    version.template.to_s.strip == Activities::RunAgentActivity::FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT.strip &&
      version.variables == VARIABLES
  end
end
