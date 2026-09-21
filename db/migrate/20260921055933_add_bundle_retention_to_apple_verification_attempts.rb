# frozen_string_literal: true

class AddBundleRetentionToAppleVerificationAttempts < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:apple_verification_attempts, :bundle_retained_until)

    add_column :apple_verification_attempts, :bundle_retained_until, :datetime,
               comment: "Deadline until which the workspace bundle binary is retained; null when no bundle was created."
  end
end
