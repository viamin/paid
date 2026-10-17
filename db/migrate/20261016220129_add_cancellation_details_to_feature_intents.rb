# frozen_string_literal: true

# @spec FEATURE-APPROVAL-020
class AddCancellationDetailsToFeatureIntents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_reference :feature_intents, :cancelled_by, index: false, comment: "User who declined the feature proposal." unless column_exists?(:feature_intents, :cancelled_by_id)
    add_index :feature_intents, :cancelled_by_id, algorithm: :concurrently unless index_exists?(:feature_intents, :cancelled_by_id)
    add_column :feature_intents, :cancelled_at, :datetime, comment: "When the feature proposal was declined." unless column_exists?(:feature_intents, :cancelled_at)
    add_column :feature_intents, :cancellation_reason, :string, comment: "Why the feature proposal was declined." unless column_exists?(:feature_intents, :cancellation_reason)
    add_column :feature_intents, :replacement_reference, :string, comment: "Optional issue, pull request, or feature reference that supersedes this proposal." unless column_exists?(:feature_intents, :replacement_reference)
    add_foreign_key :feature_intents, :users, column: :cancelled_by_id, validate: false unless foreign_key_exists?(:feature_intents, :users, column: :cancelled_by_id)
    validate_foreign_key :feature_intents, :users, column: :cancelled_by_id
  end

  def down
    remove_foreign_key :feature_intents, column: :cancelled_by_id if foreign_key_exists?(:feature_intents, :users, column: :cancelled_by_id)
    remove_index :feature_intents, :cancelled_by_id, algorithm: :concurrently if index_exists?(:feature_intents, :cancelled_by_id)
    remove_reference :feature_intents, :cancelled_by, index: false if column_exists?(:feature_intents, :cancelled_by_id)
    remove_column :feature_intents, :cancelled_at if column_exists?(:feature_intents, :cancelled_at)
    remove_column :feature_intents, :cancellation_reason if column_exists?(:feature_intents, :cancellation_reason)
    remove_column :feature_intents, :replacement_reference if column_exists?(:feature_intents, :replacement_reference)
  end
end
