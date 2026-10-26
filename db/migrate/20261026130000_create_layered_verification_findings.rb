# frozen_string_literal: true

# Generated migration could not run in the task database because its runtime role
# has BYPASSRLS; this preserves the Rails migration boundary for a normal app role.
class CreateLayeredVerificationFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :originating_audit_run, foreign_key: { to_table: :agent_runs, on_delete: :nullify }
      t.string :correspondence_claim_type
      t.string :cause_signature, null: false
      t.jsonb :source_passages, null: false, default: []
      t.text :observed_behavior
      t.text :check_limitations, null: false
      t.text :question, null: false
      t.jsonb :options, null: false, default: []
      t.jsonb :owner_actions, null: false, default: []
      t.jsonb :observations, null: false, default: []
      t.string :state, null: false, default: "unresolved"
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ],
      unique: true,
      where: "state IN ('unresolved', 'deferred')",
      name: "index_layered_verification_open_finding_identity"
  end
end
