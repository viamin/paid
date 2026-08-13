# frozen_string_literal: true

class AddAllowBotAuthoredPrAutoMergeToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :allow_bot_authored_pr_auto_merge, :boolean, default: false, null: false,
      comment: "When true, PRs authored by the project's own GitHub App bot may auto-merge without explicit owner approval"
  end
end
