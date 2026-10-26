# frozen_string_literal: true

class CreateLayeredVerificationFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :nullify }
      t.references :agent_run, foreign_key: { on_delete: :nullify }
      t.string :obligation_external_identity, null: false
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.jsonb :observations, null: false, default: []
      t.text :deferred_reason
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_external_identity, :correspondence_claim_type, :cause_signature ],
      unique: true, name: "index_layered_verification_findings_identity"
  end
end
