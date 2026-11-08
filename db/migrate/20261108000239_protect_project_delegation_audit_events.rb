# frozen_string_literal: true

# @spec PROJECT-DELEGATION-001
class ProtectProjectDelegationAuditEvents < ActiveRecord::Migration[8.1]
  def up
    create_function :protect_project_delegation_audit_event, version: 1
    create_trigger :protect_project_delegation_audit_event_update, on: :account_activity_events
    create_trigger :protect_project_delegation_audit_event_delete, on: :account_activity_events
  end

  def down
    safety_assured do
      execute "DROP TRIGGER IF EXISTS protect_project_delegation_audit_event_update ON account_activity_events"
      execute "DROP TRIGGER IF EXISTS protect_project_delegation_audit_event_delete ON account_activity_events"
      execute "DROP FUNCTION IF EXISTS protect_project_delegation_audit_event()"
    end
  end
end
