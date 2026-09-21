# frozen_string_literal: true

class AddContainerRetentionToAppleVerificationAttempts < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:apple_verification_attempts, :container_retained_until)

    add_column :apple_verification_attempts, :container_retained_until, :datetime,
               comment: "Deadline until which a failed Apple VM is retained before destroy; null when destroyed promptly or never retained."
  end
end
