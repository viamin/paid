# frozen_string_literal: true

class CreateLayeredVerificationAuditRecords < ActiveRecord::Migration[8.1]
  # @spec LAYERED-VERIFY-015
  # @spec LAYERED-VERIFY-017
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :nullify }
      t.references :agent_run, foreign_key: { on_delete: :nullify }
      t.string :obligation_external_identity, null: false
      t.string :correspondence_claim_type
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.jsonb :source_passages, null: false, default: {}
      t.jsonb :observed_behavior, null: false, default: {}
      t.text :limitations, null: false, default: ""
      t.jsonb :decision_context, null: false, default: {}
      t.timestamps
    end
    add_index :layered_verification_findings,
      %i[project_id obligation_external_identity correspondence_claim_type cause_signature],
      unique: true, name: "index_layered_verification_findings_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :check_result, foreign_key: { to_table: :layered_verification_check_results, on_delete: :nullify }
      t.references :agent_run, foreign_key: { on_delete: :nullify }
      t.jsonb :details, null: false, default: {}
      t.timestamps
    end
  end
end
