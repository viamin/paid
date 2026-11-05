# frozen_string_literal: true

class SyncEnhanceIssueStructuredQuestionsPrompt < ActiveRecord::Migration[8.1]
  PROMPT_SLUG = "goal.enhance_issue"

  # @spec ISSUE-ENHANCEMENT-020
  def up
    TenantContext.with_system_access do
      prompt = Prompt.global.find_by(slug: PROMPT_SLUG)
      next unless prompt

      template = Activities::RunAgentActivity::FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT
      next if prompt.current_version&.template.to_s&.strip == template.strip

      prompt.create_version!(template:, variables: prompt.current_version.variables, created_by: "migration",
        change_notes: "Ask for structured clarifying questions with separate supporting context")
    end
  end

  def down; end
end
