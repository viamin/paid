# frozen_string_literal: true

class AddAppleVerificationAttemptForeignKeys < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :execution_audit_events, :apple_verification_attempts, validate: false unless foreign_key_exists?(:execution_audit_events, :apple_verification_attempts)
    unless foreign_key_exists?(:execution_resource_ledger_entries, :apple_verification_attempts)
      add_foreign_key :execution_resource_ledger_entries, :apple_verification_attempts, on_delete: :nullify, validate: false
    end
  end
end
