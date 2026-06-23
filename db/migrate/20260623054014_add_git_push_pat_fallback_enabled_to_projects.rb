# frozen_string_literal: true

class AddGitPushPatFallbackEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :git_push_pat_fallback_enabled, :boolean, default: false, null: false,
      comment: "When true, an app-backed project retries a git push with its " \
               "git_push_fallback_token PAT if the GitHub App installation token is " \
               "rejected for a missing permission (e.g. a push touching .github/workflows/). " \
               "Opt-in; the App remains the default credential for every other operation."
  end
end
