# frozen_string_literal: true

class AddRetryOfAttemptToAppleVerificationAttempts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_retry_source_column
    add_retry_source_foreign_key
    add_retry_source_unique_index
  end

  def down
    remove_retry_source_unique_index
    remove_foreign_key :apple_verification_attempts, column: :retry_of_attempt_id if foreign_key_exists?(:apple_verification_attempts, column: :retry_of_attempt_id)
    remove_column :apple_verification_attempts, :retry_of_attempt_id if column_exists?(:apple_verification_attempts, :retry_of_attempt_id)
  end

  private

  def add_retry_source_column
    return if column_exists?(:apple_verification_attempts, :retry_of_attempt_id)

    add_reference :apple_verification_attempts, :retry_of_attempt, foreign_key: false, index: false,
      comment: "Terminal attempt this queued retry reruns."
  end

  def add_retry_source_foreign_key
    return if foreign_key_exists?(:apple_verification_attempts, column: :retry_of_attempt_id)

    add_foreign_key :apple_verification_attempts, :apple_verification_attempts,
      column: :retry_of_attempt_id, validate: false
  end

  def add_retry_source_unique_index
    return if index_exists?(:apple_verification_attempts, :retry_of_attempt_id, unique: true, name: "idx_apple_attempts_one_retry_per_source")

    add_index :apple_verification_attempts, :retry_of_attempt_id, unique: true,
      name: "idx_apple_attempts_one_retry_per_source", algorithm: :concurrently
  end

  def remove_retry_source_unique_index
    return unless index_exists?(:apple_verification_attempts, name: "idx_apple_attempts_one_retry_per_source")

    remove_index :apple_verification_attempts, name: "idx_apple_attempts_one_retry_per_source", algorithm: :concurrently
  end
end
