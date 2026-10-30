class AddActionHistoryStartedAtToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :action_history_started_at, :datetime,
      comment: "Earliest point from which Paid has durable action-history coverage for this subject."
    safety_assured { execute "UPDATE issues SET action_history_started_at = CURRENT_TIMESTAMP" }
  end

  def down
    remove_column :issues, :action_history_started_at
  end
end
