# frozen_string_literal: true

# @spec PROJECT-DELEGATION-010
#
# The delegation audit trail now covers more than the posture selection: a
# conservative rollback and a delegation hold placement or release are part of
# the same evidence boundary. They become append-only at the database level so
# a rollback cannot erase the history it stopped, while the supported account
# teardown still removes the tenant's events.
class ProtectProjectDelegationAuditEventsV03 < ActiveRecord::Migration[8.1]
  def up
    create_function :protect_project_delegation_audit_event, version: 3
  end

  def down
    create_function :protect_project_delegation_audit_event, version: 2
  end
end
