# frozen_string_literal: true

class ProtectProjectDelegationActionEvaluationAuditEvents < ActiveRecord::Migration[8.1]
  # @spec PROJECT-DELEGATION-003
  def up
    create_function :protect_project_delegation_audit_event, version: 4
  end

  def down
    create_function :protect_project_delegation_audit_event, version: 3
  end
end
