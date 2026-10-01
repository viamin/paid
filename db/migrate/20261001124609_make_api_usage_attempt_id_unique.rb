# frozen_string_literal: true

class MakeApiUsageAttemptIdUnique < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_api_usage_attempts_idempotency"

  disable_ddl_transaction!

  def up
    return unless table_exists?(:api_usage_attempts)

    remove_index :api_usage_attempts, name: INDEX_NAME, if_exists: true
    return if index_exists?(:api_usage_attempts, :attempt_id, name: INDEX_NAME)

    add_index :api_usage_attempts, :attempt_id, unique: true, name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    return unless table_exists?(:api_usage_attempts)

    remove_index :api_usage_attempts, name: INDEX_NAME, if_exists: true
    return if index_exists?(:api_usage_attempts, [ :attempt_id, :ordinal ], name: INDEX_NAME)

    add_index :api_usage_attempts, [ :attempt_id, :ordinal ], unique: true, name: INDEX_NAME, algorithm: :concurrently
  end
end
