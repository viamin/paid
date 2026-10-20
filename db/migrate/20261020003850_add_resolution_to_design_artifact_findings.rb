# frozen_string_literal: true

class AddResolutionToDesignArtifactFindings < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :design_artifact_findings, :resolution_state, :string,
      comment: "Operator decision: assigned, deferred, dismissed, or verified." unless column_exists?(:design_artifact_findings, :resolution_state)
    add_column :design_artifact_findings, :resolution_reason, :text,
      comment: "Required operator explanation for a non-automatic finding decision." unless column_exists?(:design_artifact_findings, :resolution_reason)
    add_reference :design_artifact_findings, :resolution_actor, index: { algorithm: :concurrently },
      comment: "User who last made the recorded finding decision." unless column_exists?(:design_artifact_findings, :resolution_actor_id)
    add_reference :design_artifact_findings, :resolution_issue, index: { algorithm: :concurrently },
      comment: "Authorized existing or newly filed issue assigned to resolve this finding." unless column_exists?(:design_artifact_findings, :resolution_issue_id)
    add_foreign_key :design_artifact_findings, :users, column: :resolution_actor_id, validate: false unless foreign_key_exists?(:design_artifact_findings, :users, column: :resolution_actor_id)
    add_foreign_key :design_artifact_findings, :issues, column: :resolution_issue_id, validate: false unless foreign_key_exists?(:design_artifact_findings, :issues, column: :resolution_issue_id)
    validate_foreign_key :design_artifact_findings, :users, column: :resolution_actor_id
    validate_foreign_key :design_artifact_findings, :issues, column: :resolution_issue_id
    add_column :design_artifact_findings, :resolution_metadata, :jsonb, null: false, default: {},
      comment: "Decision provenance, including cited revision and idempotency marker." unless column_exists?(:design_artifact_findings, :resolution_metadata)
    remove_check_constraint :design_artifact_findings, name: "chk_design_artifact_findings_status" if check_constraint_exists?(:design_artifact_findings, name: "chk_design_artifact_findings_status")
    add_check_constraint :design_artifact_findings,
      "status IN ('open', 'assigned', 'deferred', 'dismissed', 'resolved')",
      name: "chk_design_artifact_findings_status", validate: false unless check_constraint_exists?(:design_artifact_findings, name: "chk_design_artifact_findings_status")
    validate_check_constraint :design_artifact_findings, name: "chk_design_artifact_findings_status"
  end

  def down
    # The widened check constraint accepts 'assigned', 'deferred', and
    # 'dismissed'. PostgreSQL validates a new check constraint against every
    # existing row, so any rows in those statuses must be coerced to an
    # open/resolved-only value before the narrower constraint is re-added,
    # otherwise db:rollback fails before the resolution columns can be removed.
    # Down migrations on a small status table are bounded; ignore the
    # strong_migrations long-running warning for this rollback path.
    safety_assured do
      execute <<~SQL.squish
        UPDATE design_artifact_findings
        SET status = 'open'
        WHERE status IN ('assigned', 'deferred', 'dismissed')
      SQL

      remove_check_constraint :design_artifact_findings, name: "chk_design_artifact_findings_status"
      add_check_constraint :design_artifact_findings, "status IN ('open', 'resolved')",
        name: "chk_design_artifact_findings_status", validate: false
      remove_foreign_key :design_artifact_findings, :issues, column: :resolution_issue_id, if_exists: true
      remove_foreign_key :design_artifact_findings, :users, column: :resolution_actor_id, if_exists: true
      remove_column :design_artifact_findings, :resolution_metadata
      remove_column :design_artifact_findings, :resolution_reason
      remove_column :design_artifact_findings, :resolution_state
    end
  end
end
