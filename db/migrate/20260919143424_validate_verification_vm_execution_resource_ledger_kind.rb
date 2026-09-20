# frozen_string_literal: true

class ValidateVerificationVmExecutionResourceLedgerKind < ActiveRecord::Migration[8.1]
  def up
    return unless check_constraint_exists?(:execution_resource_ledger_entries, name: AllowVerificationVmExecutionResourceLedgerKind::CONSTRAINT_NAME)

    validate_check_constraint :execution_resource_ledger_entries, name: AllowVerificationVmExecutionResourceLedgerKind::CONSTRAINT_NAME
  end

  def down
  end
end
