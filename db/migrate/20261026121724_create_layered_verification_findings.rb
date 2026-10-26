# frozen_string_literal: true

class CreateLayeredVerificationFindings < ActiveRecord::Migration[8.1]
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-017
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :restrict }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :restrict }
      t.references :originating_audit_run, null: false, foreign_key: { to_table: :agent_runs, on_delete: :restrict }
      t.string :correspondence_claim_type
      t.string :cause_signature, null: false
      t.jsonb :source_claims, null: false, default: {}
      t.text :observed_behavior, null: false
      t.text :limitations, null: false
      t.text :question, null: false
      t.jsonb :options, null: false, default: []
      t.jsonb :consequences, null: false, default: []
      t.string :status, null: false, default: "open"
      t.timestamps
    end
    add_index :layered_verification_findings, [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ], unique: true, name: "index_layered_verification_findings_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :check_result, null: false, foreign_key: { to_table: :layered_verification_check_results, on_delete: :restrict }
      t.references :agent_run, null: false, foreign_key: { on_delete: :restrict }
      t.jsonb :provenance, null: false, default: {}
      t.timestamps
    end
    add_index :layered_verification_finding_observations, [ :finding_id, :check_result_id ], unique: true, name: "index_layered_verification_finding_observations_unique_evidence"
  end
end
