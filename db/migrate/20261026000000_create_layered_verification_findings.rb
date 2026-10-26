# frozen_string_literal: true

# @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-017
class CreateLayeredVerificationFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :restrict }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :restrict }
      t.references :agent_run, null: false, foreign_key: { on_delete: :restrict }
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.jsonb :source_passages, null: false, default: []
      t.jsonb :observed_behavior, null: false, default: {}
      t.jsonb :check_limitations, null: false, default: []
      t.jsonb :decision, null: false, default: {}
      t.jsonb :observation_history, null: false, default: []
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_id, :cause_signature ],
      unique: true,
      where: "status = 'open'",
      name: "index_layered_verification_open_finding_identity"
  end
end
