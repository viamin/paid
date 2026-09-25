# frozen_string_literal: true

class AddFinalizedAtToAppleVerificationAttempts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_finalization_marker
    add_incomplete_finalization_index
  end

  def down
    remove_incomplete_finalization_index
    remove_column :apple_verification_attempts, :finalized_at if column_exists?(:apple_verification_attempts, :finalized_at)
  end

  private

  def add_finalization_marker
    return if column_exists?(:apple_verification_attempts, :finalized_at)

    add_column :apple_verification_attempts, :finalized_at, :datetime,
      comment: "When VM cleanup and credential revocation completed for this terminal attempt."
  end

  def add_incomplete_finalization_index
    return if index_exists?(:apple_verification_attempts, :finalized_at, name: "idx_apple_attempts_incomplete_finalization")

    add_index :apple_verification_attempts, :finalized_at,
      where: "finalized_at IS NULL",
      name: "idx_apple_attempts_incomplete_finalization",
      algorithm: :concurrently
  end

  def remove_incomplete_finalization_index
    return unless index_exists?(:apple_verification_attempts, name: "idx_apple_attempts_incomplete_finalization")

    remove_index :apple_verification_attempts,
      name: "idx_apple_attempts_incomplete_finalization",
      algorithm: :concurrently
  end
end
