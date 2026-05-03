class CreateIssueMergeSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :issue_merge_subscriptions,
      comment: "One-shot per-user subscriptions for issue completion or pull request merge notifications." do |t|
      t.references :issue, null: false, foreign_key: true,
        comment: "The synced issue row. Pull requests also use the issues table."
      t.references :user, null: false, foreign_key: true,
        comment: "The user who should receive the notification."
      t.string :subscription_type, null: false, default: "on_merge",
        comment: "Notification trigger type. on_merge covers PR merges and issue completion."

      t.timestamps
    end

    add_index :issue_merge_subscriptions, [ :issue_id, :user_id, :subscription_type ],
      unique: true, name: "index_issue_merge_subscriptions_on_dedup"
  end
end
