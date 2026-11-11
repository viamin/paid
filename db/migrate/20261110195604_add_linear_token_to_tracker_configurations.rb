# frozen_string_literal: true

# @spec UNIFIED-WORK-ITEMS-002
class AddLinearTokenToTrackerConfigurations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_reference :tracker_configurations, :linear_token, index: { algorithm: :concurrently },
      comment: "Selected account Linear API key for the single workspace connection." unless column_exists?(:tracker_configurations, :linear_token_id)
    add_foreign_key :tracker_configurations, :linear_tokens, column: :linear_token_id,
      validate: false unless foreign_key_exists?(:tracker_configurations, :linear_tokens, column: :linear_token_id)
    validate_foreign_key :tracker_configurations, :linear_tokens, column: :linear_token_id
  end

  def down
    remove_foreign_key :tracker_configurations, :linear_tokens, column: :linear_token_id, if_exists: true
    remove_reference :tracker_configurations, :linear_token, foreign_key: false, if_exists: true
  end
end
