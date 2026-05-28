# frozen_string_literal: true

class CreateRemediationDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :remediation_decisions,
      comment: "Audits self-heal diagnoses and proposed remediation actions for recurring agent-run failure fingerprints." do |t|
      t.references :account, null: false, foreign_key: true, comment: "Owning account for tenant isolation and auditing."
      t.string :fingerprint, null: false, comment: "Stable pattern fingerprint used to dedupe recurring diagnoses."
      t.text :root_cause, null: false, comment: "Human-readable diagnosis summary shown in notifications and audits."
      t.decimal :confidence, precision: 4, scale: 3, null: false, default: 0.0,
        comment: "Model confidence score from 0.0 to 1.0 for the proposed action."
      t.jsonb :evidence_pointers, null: false, default: [], comment: "Pointers into the sanitized evidence bundle that support the diagnosis."
      t.string :proposed_action, null: false, comment: "Frozen action enum proposed by the diagnosis pipeline."
      t.string :action_target_type, null: false, comment: "Normalized target category such as account, project, runner, or runner_field."
      t.string :action_target_id, comment: "Opaque target identifier for the proposed action."
      t.jsonb :action_target_metadata, null: false, default: {}, comment: "Extra target details such as a runner field name."
      t.string :status, null: false, default: "proposed", comment: "Lifecycle state: proposed, approved, applied, skipped, failed, or reverted."
      t.datetime :applied_at, comment: "When the remediation action was applied."
      t.references :applied_by, foreign_key: { to_table: :users }, comment: "User who approved or applied the action when it was manual."
      t.jsonb :revert_data, null: false, default: {}, comment: "Structured data needed to reverse an applied remediation unambiguously."
      t.integer :pre_remediation_failure_count, comment: "Observed failure count for the fingerprint before remediation was proposed."
      t.integer :post_remediation_failure_count, comment: "Observed failure count for the fingerprint after remediation evaluation."
      t.string :outcome, comment: "Evaluation result for the remediation: improved, unchanged, or regressed."
      t.integer :occurrence_count, null: false, default: 1, comment: "How many detections collapsed into this deduped decision row."
      t.timestamps
    end

    add_index :remediation_decisions, [ :account_id, :fingerprint, :created_at ], name: "idx_remediation_decisions_dedup_lookup"
    add_index :remediation_decisions, [ :account_id, :status, :created_at ], name: "idx_remediation_decisions_account_status_created"
    add_index :remediation_decisions, :proposed_action
  end
end
