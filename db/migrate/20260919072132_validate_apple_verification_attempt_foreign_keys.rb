# frozen_string_literal: true

class ValidateAppleVerificationAttemptForeignKeys < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :execution_audit_events, :apple_verification_attempts
    validate_foreign_key :execution_resource_ledger_entries, :apple_verification_attempts
  end
end
