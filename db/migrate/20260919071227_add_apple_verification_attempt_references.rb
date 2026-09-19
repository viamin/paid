# frozen_string_literal: true

class AddAppleVerificationAttemptReferences < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    unless column_exists?(:execution_audit_events, :apple_verification_attempt_id)
      add_reference :execution_audit_events, :apple_verification_attempt, foreign_key: false, index: { algorithm: :concurrently }, comment: "Apple verification attempt the append-only event concerns."
    end
    unless column_exists?(:execution_resource_ledger_entries, :apple_verification_attempt_id)
      add_reference :execution_resource_ledger_entries, :apple_verification_attempt, foreign_key: false, index: { algorithm: :concurrently }, comment: "Apple verification attempt that owns this external resource."
    end
  end
end
