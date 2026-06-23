# frozen_string_literal: true

class AddGitPushFallbackTokenToProjects < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :projects, :git_push_fallback_token,
      null: true,
      index: { algorithm: :concurrently },
      comment: "Optional PAT (selected in project settings) used as the git push " \
               "credential when git_push_pat_fallback_enabled is set and the GitHub App " \
               "installation token is rejected for a missing permission (e.g. a push " \
               "under .github/workflows/). The App stays the default for all other operations."
    safety_assured do
      add_foreign_key :projects, :github_tokens, column: :git_push_fallback_token_id, validate: false
    end
  end
end
