# frozen_string_literal: true

class AddAppleVerificationAttemptForeignKeys < ActiveRecord::Migration[8.1]
  def up
    unless foreign_key_exists?(:execution_audit_events, :apple_verification_attempts)
      add_foreign_key :execution_audit_events, :apple_verification_attempts, on_delete: :nullify, validate: false
    end
    unless foreign_key_exists?(:execution_resource_ledger_entries, :apple_verification_attempts)
      add_foreign_key :execution_resource_ledger_entries, :apple_verification_attempts, on_delete: :nullify, validate: false
    end
  end

  def down
    if foreign_key_exists?(:execution_audit_events, :apple_verification_attempts)
      remove_foreign_key :execution_audit_events, :apple_verification_attempts
    end
    if foreign_key_exists?(:execution_resource_ledger_entries, :apple_verification_attempts)
      remove_foreign_key :execution_resource_ledger_entries, :apple_verification_attempts
    end
  end
end
