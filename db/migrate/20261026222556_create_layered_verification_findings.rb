# frozen_string_literal: true

class CreateLayeredVerificationFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: true
      t.references :obligation, null: false, foreign_key: true
      t.references :correspondence_claim, null: false, foreign_key: true
      t.references :originating_audit_run, null: false, foreign_key: true
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.jsonb :source_passages, null: false, default: []
      t.text :observed_behavior, null: false
      t.text :check_limitations, null: false
      t.jsonb :decision_options, null: false, default: []
      t.text :deferred_reason
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_id, :cause_signature ],
      unique: true, name: "index_layered_verification_findings_identity"
  end
end
