# frozen_string_literal: true

class AddAutoMergeDiagnosticsToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :auto_merge_blockers, :jsonb,
      if_not_exists: true,
      comment: "Latest authoritative auto-merge blocker snapshot from the PR scanner. Stores failed blockers separately from checks that were not evaluated because an earlier gate already failed."
    add_column :issues, :auto_merge_evaluated_at, :datetime,
      if_not_exists: true,
      comment: "When the latest authoritative auto-merge blocker snapshot was recorded by the PR scanner."
  end
end
