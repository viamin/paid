# frozen_string_literal: true

# Generated migration command could not boot because the supplied DATABASE_URL
# uses a PostgreSQL superuser; this follows the project's migration conventions.
class CreateLayeredVerificationAuditRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :nullify }
      t.references :agent_run, foreign_key: { on_delete: :nullify }
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.jsonb :source_passages, null: false, default: {}
      t.jsonb :observed_behavior, null: false, default: {}
      t.text :limitations, null: false, default: ""
      t.jsonb :observations, null: false, default: []
      t.datetime :resolved_at
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ],
      unique: true, name: "idx_layered_verification_finding_identity"
  end
end
