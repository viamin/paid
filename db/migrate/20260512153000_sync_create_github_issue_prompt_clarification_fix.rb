# frozen_string_literal: true

class SyncCreateGithubIssuePromptClarificationFix < ActiveRecord::Migration[8.1]
  CHANGE_NOTES = "Sync create-issue prompt clarification fix"

  def up
    prompt = Prompt.global.find_by(slug: Prompts::GoalCreateGithubIssue::PROMPT_SLUG)
    return unless prompt
    return if synced?(prompt.current_version)

    prompt.create_version!(
      template: Prompts::GoalCreateGithubIssue::TEMPLATE,
      variables: Prompts::GoalCreateGithubIssue::VARIABLES,
      created_by: "migration",
      change_notes: CHANGE_NOTES
    )
  end

  def down
  end

  private

  def normalize(template)
    template.to_s.strip
  end

  def synced?(version)
    return false unless version

    normalize(version.template) == normalize(Prompts::GoalCreateGithubIssue::TEMPLATE) &&
      version.variables == Prompts::GoalCreateGithubIssue::VARIABLES
  end
end
