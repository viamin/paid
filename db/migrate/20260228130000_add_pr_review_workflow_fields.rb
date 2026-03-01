# frozen_string_literal: true

class AddPrReviewWorkflowFields < ActiveRecord::Migration[8.1]
  def change
    # Projects: owner reviewer, merge method, max draft review rounds
    add_column :projects, :owner_reviewer_login, :string, null: true
    add_column :projects, :merge_method, :string, default: "squash", null: false
    add_column :projects, :max_draft_review_rounds, :integer, default: 10, null: false

    # Issues: PR review phase tracking
    add_column :issues, :pr_review_phase, :string, default: "draft", null: false
    add_column :issues, :draft_review_count, :integer, default: 0, null: false
    add_index :issues, [:project_id, :pr_review_phase],
      where: "(is_pull_request = true AND github_state = 'open')",
      name: "idx_issues_pr_review_phase"

    # Existing open PRs are already non-draft on GitHub, so set them to "ready"
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE issues
          SET pr_review_phase = 'ready'
          WHERE is_pull_request = true AND github_state = 'open'
        SQL
      end
    end
  end
end
