# frozen_string_literal: true

# @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-017 @spec LAYERED-VERIFY-023
class CreateLayeredVerificationAuditRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :nullify }
      t.references :agent_run, null: false, foreign_key: { on_delete: :restrict }
      t.string :cause_signature, null: false
      t.string :correspondence_claim_type, null: false, default: "none"
      t.string :status, null: false, default: "unresolved"
      t.jsonb :source_passages, null: false, default: []
      t.text :observed_behavior, null: false
      t.text :question, null: false
      t.jsonb :options, null: false, default: []
      t.jsonb :consequences, null: false, default: []
      t.text :deferred_reason
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ],
      unique: true,
      where: "status = 'unresolved'",
      name: "index_layered_verification_open_finding_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :check_result, foreign_key: { to_table: :layered_verification_check_results, on_delete: :nullify }
      t.references :agent_run, null: false, foreign_key: { on_delete: :restrict }
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end
  end
end
