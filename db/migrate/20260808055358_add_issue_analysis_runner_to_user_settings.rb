# frozen_string_literal: true

class AddIssueAnalysisRunnerToUserSettings < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:user_settings, :issue_analysis_runner)
      add_column :user_settings, :issue_analysis_runner, :string, default: "", null: false,
        comment: "Preferred runner key for analyze_issue LLM assessment. Blank falls back to the owner's chat-enabled runners."
    end

    unless column_exists?(:user_settings, :issue_analysis_fallback_runners)
      add_column :user_settings, :issue_analysis_fallback_runners, :jsonb, default: [], null: false,
        comment: "Ordered fallback runner keys for analyze_issue when the primary runner is unavailable."
    end
  end
end
