# frozen_string_literal: true

class AddBundleRetentionToAppleVerificationAttempts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    unless column_exists?(:apple_verification_attempts, :bundle_retained_until)
      add_column :apple_verification_attempts, :bundle_retained_until, :datetime,
                 comment: "Deadline until which the workspace bundle binary is retained; null when no bundle was created."
    end

    return if index_exists?(:apple_verification_attempts, :bundle_retained_until, name: "idx_apple_attempts_bundle_retained_until")

    add_index :apple_verification_attempts, :bundle_retained_until,
              where: "bundle_retained_until IS NOT NULL",
              name: "idx_apple_attempts_bundle_retained_until",
              algorithm: :concurrently
  end

  def down
    remove_index :apple_verification_attempts, name: "idx_apple_attempts_bundle_retained_until", algorithm: :concurrently, if_exists: true
    remove_column :apple_verification_attempts, :bundle_retained_until if column_exists?(:apple_verification_attempts, :bundle_retained_until)
  end
end
