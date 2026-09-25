# frozen_string_literal: true

class AddRequestedCaptureToAppleVerificationAttempts < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:apple_verification_attempts, :requested_capture)

    add_column :apple_verification_attempts, :requested_capture, :string,
      comment: "Declared capture selected for this attempt; null for full workflow verification."
  end

  def down
    remove_column :apple_verification_attempts, :requested_capture if column_exists?(:apple_verification_attempts, :requested_capture)
  end
end
