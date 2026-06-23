# frozen_string_literal: true

class AddGitCredentialFallbackActiveToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :git_credential_fallback_active, :boolean, default: false, null: false,
      comment: "Transient flag set by Containers::GitOperations only while retrying a " \
               "push with the project's git_push_fallback_token PAT. The git-credentials " \
               "proxy serves the fallback PAT (instead of the App installation token) while " \
               "this is true, then it is cleared. Not part of run history/state."
  end
end
