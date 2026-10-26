class CreateLayeredVerificationAuditReports < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :agent_run, foreign_key: true
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.jsonb :source_passages, null: false, default: []
      t.text :observed_behavior, null: false
      t.text :limitations, null: false
      t.jsonb :observations, null: false, default: []
      t.jsonb :decision_options, null: false, default: []
      t.datetime :resolved_at
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ],
      unique: true,
      where: "status IN ('open', 'deferred')",
      name: "index_layered_verification_open_finding_identity"
  end
end
