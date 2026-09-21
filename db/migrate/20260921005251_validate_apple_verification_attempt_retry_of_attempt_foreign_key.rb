# frozen_string_literal: true

class ValidateAppleVerificationAttemptRetryOfAttemptForeignKey < ActiveRecord::Migration[8.1]
  def up
    validate_foreign_key :apple_verification_attempts, column: :retry_of_attempt_id
  end

  def down
    # Validation does not create a separate schema object; the creating migration owns removal.
  end
end
