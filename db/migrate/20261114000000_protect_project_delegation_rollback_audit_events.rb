# frozen_string_literal: true

# @spec PROJECT-DELEGATION-001
class ProtectProjectDelegationRollbackAuditEvents < ActiveRecord::Migration[8.1]
  def up
    create_function :protect_project_delegation_audit_event, version: 3
  end

  def down
    create_function :protect_project_delegation_audit_event, version: 2
  end
end
