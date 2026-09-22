# frozen_string_literal: true

class AddContainerRetentionToAppleVerificationAttempts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    unless column_exists?(:apple_verification_attempts, :container_retained_until)
      add_column :apple_verification_attempts, :container_retained_until, :datetime,
                 comment: "Deadline until which a failed Apple VM is retained before destroy; null when destroyed promptly or never retained."
    end

    return if index_exists?(:apple_verification_attempts, :container_retained_until, name: "idx_apple_attempts_container_retained_until")

    add_index :apple_verification_attempts, :container_retained_until,
              where: "container_retained_until IS NOT NULL",
              name: "idx_apple_attempts_container_retained_until",
              algorithm: :concurrently
  end

  def down
    remove_index :apple_verification_attempts, name: "idx_apple_attempts_container_retained_until", algorithm: :concurrently, if_exists: true
    remove_column :apple_verification_attempts, :container_retained_until if column_exists?(:apple_verification_attempts, :container_retained_until)
  end
end
