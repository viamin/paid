# frozen_string_literal: true

class CreateLayeredVerificationAuditRecords < ActiveRecord::Migration[8.1]
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-017 @spec LAYERED-VERIFY-023 @spec LAYERED-VERIFY-024
  def change
    create_table :layered_verification_audit_reports do |t|
      t.references :agent_run, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :business_intent_view, null: false, default: {}
      t.jsonb :verification_coverage_view, null: false, default: {}
      t.jsonb :progress, null: false, default: {}
      t.text :waiting_reason
      t.timestamps
    end

    create_table :layered_verification_findings do |t|
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :originating_audit_run, null: false, foreign_key: { to_table: :agent_runs, on_delete: :restrict }
      t.references :correspondence_claim, foreign_key: { to_table: :layered_verification_correspondence_claims, on_delete: :nullify }
      t.string :cause_signature, null: false
      t.string :status, null: false, default: "unresolved"
      t.jsonb :details, null: false, default: {}
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :layered_verification_findings, [ :obligation_id, :correspondence_claim_id, :cause_signature ], unique: true,
      where: "status = 'unresolved'", name: "index_layered_verification_open_finding_identity"

    create_table :layered_verification_finding_observations do |t|
      t.references :finding, null: false, foreign_key: { to_table: :layered_verification_findings, on_delete: :cascade }
      t.references :check_result, null: false, foreign_key: { to_table: :layered_verification_check_results, on_delete: :restrict }
      t.references :audit_run, null: false, foreign_key: { to_table: :agent_runs, on_delete: :restrict }
      t.jsonb :provenance, null: false, default: {}
      t.timestamps
    end
    add_index :layered_verification_finding_observations, [ :finding_id, :check_result_id ], unique: true,
      name: "index_layered_verification_finding_observations_identity"

    create_table :layered_verification_review_packages do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :audit_run, foreign_key: { to_table: :agent_runs, on_delete: :nullify }
      t.string :digest, null: false
      t.jsonb :bound_inputs, null: false, default: {}
      t.datetime :approved_at
      t.references :approved_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :layered_verification_review_packages, [ :project_id, :digest ], unique: true
  end
end
