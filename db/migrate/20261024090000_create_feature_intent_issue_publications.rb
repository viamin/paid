# frozen_string_literal: true

class CreateFeatureIntentIssuePublications < ActiveRecord::Migration[8.1]
  def change
    create_table :feature_intent_issue_publications,
      comment: "Durable GitHub issue-create receipts for planning-held feature work." do |t|
      t.references :feature_intent, null: false, foreign_key: true
      t.string :task_digest, limit: 16, null: false, comment: "Stable planning-held task identity."
      t.bigint :remote_issue_id, comment: "GitHub issue node id recorded immediately after creation."
      t.integer :remote_issue_number, comment: "GitHub issue number used to reconcile a failed local sync."

      t.timestamps
    end

    add_index :feature_intent_issue_publications, [ :feature_intent_id, :task_digest ], unique: true,
      name: "index_feature_intent_issue_publications_on_task"
  end
end
