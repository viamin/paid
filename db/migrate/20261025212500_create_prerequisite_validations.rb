# frozen_string: true

# Bounded evidence records for the capability-aware Inbox execution validation
# (#4643 / docs/intent/prerequisite-evidence-validation/). One row per
# validation generation for a prerequisite owner issue; execution itself runs
# through a synthetic AgentRun referenced by agent_run_id.
class CreatePrerequisiteValidations < ActiveRecord::Migration[8.1]
  def change
    create_table :prerequisite_validations, comment: "Capability-aware execution validations that collect technical prerequisite evidence for a prerequisite owner issue." do |t|
      t.references :account, null: false, foreign_key: true, comment: "Tenant that owns the validation."
      t.references :project, null: false, foreign_key: true, comment: "Project whose execution infrastructure was validated."
      t.references :issue, comment: "Prerequisite owner issue the evidence links back to."
      t.references :requested_by, foreign_key: { to_table: :users }, comment: "Operator who started the validation."
      t.references :agent_run, comment: "Synthetic run that carried the execution evidence."

      t.string :status, null: false, default: "pending",
        comment: "pending | running | succeeded | partial | failed | cancelled | unavailable | blocked"
      t.boolean :include_tool_sidecar, null: false, default: true, comment: "Whether the tool-sidecar interaction check was requested."
      t.string :analyzer_command, comment: "Bounded, operator-selected native analyzer command (defaults to the read-only scc probe)."
      t.string :scope_digest, null: false, default: "", comment: "Digest of the policy inputs (flag state, allowlist, selected tool entry) captured at start."

      t.jsonb :capability_snapshot, null: false, default: {}, comment: "Host readiness, rollout-flag, allowlist, and tool-entry state captured when the validation ran."
      t.jsonb :blockers, null: false, default: [], comment: "Array of {check, reason, authorized_action} entries naming the exact authorized setup/approval action."
      t.jsonb :result, null: false, default: {}, comment: "Per-check evidence: stdout/stderr/exit status, image/checkout/tool identity, endpoint response, cleanup evidence."

      t.datetime :started_at, comment: "When execution began (nil while pending)."
      t.datetime :completed_at, comment: "When the validation reached a terminal status."
      t.timestamps
    end

    add_index :prerequisite_validations, %i[project_id created_at id],
      name: "index_prerequisite_validations_project_created"
    add_index :prerequisite_validations, %i[issue_id created_at id],
      name: "index_prerequisite_validations_issue_created"
    # Uniqueness on issue_id alone (not status+issue_id): at most one active
    # validation per prerequisite owner issue, regardless of which active
    # status each row carries.
    add_index :prerequisite_validations, :issue_id,
      unique: true,
      where: "status IN ('pending', 'running')",
      name: "index_prerequisite_validations_one_active_per_issue"
  end
end
