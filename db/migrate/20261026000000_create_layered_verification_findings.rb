# frozen_string_literal: true

class CreateLayeredVerificationFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :originating_audit_run, null: false, foreign_key: { to_table: :agent_runs, on_delete: :restrict }
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.text :source_passages, null: false
      t.text :observed_behavior, null: false
      t.text :question, null: false
      t.jsonb :options, null: false, default: {}
      t.jsonb :consequences, null: false, default: {}
      t.text :limitations, null: false
      t.string :status, null: false, default: "open"
      t.text :deferred_reason
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ],
      unique: true,
      where: "status IN ('open', 'deferred')",
      name: "index_layered_verification_open_findings_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :check_result, null: false, foreign_key: { to_table: :layered_verification_check_results, on_delete: :restrict }
      t.datetime :observed_at, null: false
      t.timestamps
    end

    add_index :layered_verification_finding_observations,
      [ :finding_id, :check_result_id ], unique: true,
      name: "index_layered_verification_finding_observations_identity"
  end
end
