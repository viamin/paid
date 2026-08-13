# frozen_string_literal: true

class AddPrScanSettingsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :auto_scan_prs, :boolean, default: true, null: false
    add_column :projects, :max_pr_followup_runs, :integer, default: 3, null: false
    add_column :projects, :pr_action_labels, :jsonb, default: [], null: false
    add_column :projects, :auto_fix_merge_conflicts, :boolean, default: false, null: false

    add_column :issues, :pr_followup_count, :integer, default: 0, null: false
  end
end
