# frozen_string_literal: true

class CreateProjectDelegationAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :project_delegation_audit_events do |t|
      t.bigint :project_id, null: false, comment: "Project this audit event belongs to"
      t.bigint :account_id, null: false, comment: "Account this event is scoped to"
      t.string :event_type, null: false, comment: "Type of audit event: posture_changed, checkpoint_settled, action_admitted, action_completed, decision_routed"
      t.bigint :actor_id, comment: "User who triggered this event (null if system-initiated)"
      t.string :actor_name, comment: "Actor name for system events"
      t.jsonb :event_data, default: {}, null: false, comment: "Immutable event details: previous_posture, new_posture, actor, action_class, evidence_references, decision_details, etc."
      t.jsonb :evidence_snapshot, default: {}, null: false, comment: "Snapshot of design, acceptance, and evidence revisions at event time"
      t.string :revision_signature, comment: "Policy signature or other revision identifier at event time"
      t.datetime :created_at, null: false

      t.index [:project_id, :created_at], name: "index_project_delegation_audit_on_project_created"
      t.index [:account_id, :created_at], name: "index_project_delegation_audit_on_account_created"
      t.index [:event_type], name: "index_project_delegation_audit_on_event_type"
      t.index [:actor_id], name: "index_project_delegation_audit_on_actor_id"
    end

    add_foreign_key :project_delegation_audit_events, :projects, validate: false
    add_foreign_key :project_delegation_audit_events, :accounts, validate: false
    add_foreign_key :project_delegation_audit_events, :users, column: :actor_id, validate: false
  end
end
