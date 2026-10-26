# frozen_string_literal: true

# @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-017 @spec LAYERED-VERIFY-023
class CreateLayeredVerificationAuditRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :nullify }
      t.references :audit_run, null: false, foreign_key: { to_table: :agent_runs, on_delete: :restrict }
      t.string :correspondence_claim_type, null: false
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "open"
      t.text :source_passages, null: false
      t.text :observed_behavior, null: false
      t.text :limitations, null: false
      t.text :question, null: false
      t.jsonb :options, null: false, default: []
      t.jsonb :links, null: false, default: {}
      t.timestamps
    end
    add_index :layered_verification_findings,
      %i[project_id obligation_id correspondence_claim_type cause_signature],
      unique: true, where: "status = 'open'", name: "index_layered_verification_open_finding_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :audit_run, null: false, foreign_key: { to_table: :agent_runs, on_delete: :restrict }
      t.references :check_result, foreign_key: { to_table: :layered_verification_check_results, on_delete: :nullify }
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end

    create_table :layered_verification_review_packages do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :package_digest, null: false
      t.integer :revision, null: false, default: 1
      t.jsonb :bound_inputs, null: false, default: {}
      t.datetime :approved_at
      t.references :approved_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :layered_verification_review_packages, %i[project_id package_digest revision],
      unique: true, name: "index_layered_verification_review_packages_identity"
  end
end
