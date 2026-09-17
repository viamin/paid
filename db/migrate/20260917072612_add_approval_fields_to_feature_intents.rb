# frozen_string_literal: true

# @spec FEATURE-APPROVAL-009 @spec FEATURE-APPROVAL-010
class AddApprovalFieldsToFeatureIntents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :feature_intents, :approved_by_id, :bigint, comment: "User who recorded the Inbox Mark approved decision for the current design revision."
    add_column :feature_intents, :approved_at, :datetime, comment: "When the current design revision was approved."
    add_column :feature_intents, :approved_pr_heads, :jsonb, null: false, default: {}, comment: "Design PR number => head SHA snapshot the human approved; a later commit on any key makes the approval stale."

    add_foreign_key :feature_intents, :users, column: :approved_by_id, validate: false
    add_index :feature_intents, :approved_by_id, algorithm: :concurrently
  end
end
