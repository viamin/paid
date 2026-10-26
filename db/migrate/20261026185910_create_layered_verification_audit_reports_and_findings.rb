class CreateLayeredVerificationAuditReportsAndFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_audit_reports do |t|
      t.references :agent_run, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :business_intent_validation, null: false, default: {}
      t.jsonb :verification_coverage, null: false, default: {}
      t.jsonb :progress, null: false, default: {}
      t.jsonb :waiting_reasons, null: false, default: []
      t.timestamps
    end

    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :audit_run, null: false, foreign_key: { to_table: :agent_runs }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims }
      t.string :cause_signature, null: false
      t.jsonb :source_passages, null: false, default: []
      t.jsonb :claims, null: false, default: []
      t.text :observed_behavior, null: false
      t.jsonb :check_limitations, null: false, default: []
      t.text :question, null: false
      t.jsonb :options, null: false, default: []
      t.jsonb :owner_actions, null: false, default: []
      t.datetime :deferred_at
      t.text :deferral_reason
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :layered_verification_findings, [ :project_id, :obligation_id, :correspondence_claim_id, :cause_signature ], unique: true, name: "index_layered_verification_findings_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :audit_run, null: false, foreign_key: { to_table: :agent_runs }
      t.references :check_result, foreign_key: { to_table: :layered_verification_check_results }
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end
    add_index :layered_verification_finding_observations, [ :finding_id, :audit_run_id, :check_result_id ], unique: true, name: "index_layered_verification_finding_observations_identity"
  end
end
