# frozen_string_literal: true

class AllowVerificationVmExecutionResourceLedgerKind < ActiveRecord::Migration[8.1]
  CONSTRAINT_NAME = "chk_execution_resource_ledger_kind_valid"
  RESOURCE_KINDS = %w[
    primary_environment service sidecar workspace network preview_tunnel
    temporary_storage verification_vm
  ].freeze

  def up
    replace_resource_kind_constraint(RESOURCE_KINDS)
  end

  def down
    replace_resource_kind_constraint(RESOURCE_KINDS - [ "verification_vm" ])
  end

  private

  def replace_resource_kind_constraint(resource_kinds)
    return unless table_exists?(:execution_resource_ledger_entries)

    remove_check_constraint :execution_resource_ledger_entries, name: CONSTRAINT_NAME if check_constraint_exists?(:execution_resource_ledger_entries, name: CONSTRAINT_NAME)
    add_check_constraint :execution_resource_ledger_entries,
      "resource_kind IN (#{resource_kinds.map { |kind| quote(kind) }.join(', ')})",
      name: CONSTRAINT_NAME,
      validate: false
  end
end
