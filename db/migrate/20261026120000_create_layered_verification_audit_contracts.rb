# frozen_string_literal: true

# @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
# @spec LAYERED-VERIFY-017 @spec LAYERED-VERIFY-023
class CreateLayeredVerificationAuditContracts < ActiveRecord::Migration[8.1]
  def up
    create_table :layered_verification_audits do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      # A request is persisted before its human confirmation and therefore
      # before Dispatch creates the issue-less AgentRun. Keeping this nullable
      # is what lets every entry point show the resolved scope and plan before
      # execution is authorized.
      t.references :agent_run, foreign_key: { on_delete: :cascade }
      t.references :initiating_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :trigger_type, null: false, comment: "Which entry point requested the audit (manual UI, chat, MCP, pull request, schedule)."
      t.string :status, null: false, default: "planned",
        comment: "planned before dispatch, then dispatched, running, completed, failed, or cancelled."
      t.text :scope_description, null: false, comment: "The bounded business slice this audit covers."
      t.jsonb :sources, null: false, default: [], comment: "Resolved source references (path plus kind) the audit reads."
      t.string :target_revision, comment: "The repository revision every check in this audit is bound to."
      t.jsonb :budget, null: false, default: {}, comment: "Bounded budget (checks, tokens, duration) the audit may spend."
      t.jsonb :plan, null: false, default: {}, comment: "The verification plan: selected checks, fit, exclusions, inputs, assumptions, gaps."
      t.integer :plan_revision, null: false, default: 1
      t.jsonb :report, null: false, default: {}, comment: "Synthesized report: per-obligation coverage plus the two review views."
      t.jsonb :progress, null: false, default: {}, comment: "Progress of the running audit (checks completed, current check)."
      t.string :waiting_reason, comment: "Why the audit is waiting, when it is waiting."
      t.datetime :cancelled_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :layered_verification_audits, :agent_run_id, unique: true
    add_index :layered_verification_audits, [ :project_id, :status ]

    create_table :layered_verification_findings do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :obligation, null: false, foreign_key: { to_table: :layered_verification_obligations, on_delete: :cascade }
      t.references :agent_run, foreign_key: { on_delete: :nullify }
      t.string :correspondence_claim_type, null: false, comment: "The correspondence claim the discrepancy was detected against."
      t.string :cause_signature, null: false, comment: "Stable identifier of the discrepancy's cause, judged by the detecting check."
      t.string :status, null: false, default: "open", comment: "open, deferred, or resolved."
      t.text :question, null: false, comment: "Why a human decision is needed."
      t.jsonb :options, null: false, default: [], comment: "Possible resolutions with their consequences."
      t.jsonb :owner_actions, null: false, default: [], comment: "Owner actions available for this finding."
      t.jsonb :source_passages, null: false, default: [], comment: "Conflicting source, model, or specification claims."
      t.text :observed_behavior, null: false, comment: "Observed implementation behavior the check found."
      t.text :limitations, null: false, comment: "What the detecting check could not establish."
      t.string :external_revision, comment: "The obligation revision this finding was recorded against."
      t.jsonb :observations, null: false, default: [], comment: "Every observation attached to this finding, newest last."
      t.text :deferral_reason
      t.datetime :deferred_at
      t.datetime :resolved_at
      t.references :resolved_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.text :resolution_note
      t.timestamps
    end

    add_index :layered_verification_findings,
      [ :project_id, :obligation_id, :correspondence_claim_type, :cause_signature ],
      unique: true,
      name: "index_layered_verification_findings_identity"
    add_index :layered_verification_findings, [ :project_id, :status ]

    create_table :layered_verification_review_packages do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.integer :package_revision, null: false, default: 1
      t.string :digest, null: false, comment: "Digest over the bound inputs; identifies the package, never proves completeness."
      t.jsonb :obligation_revisions, null: false, default: []
      t.jsonb :scope, null: false, default: {}
      t.integer :plan_revision, null: false, default: 1
      t.jsonb :check_result_references, null: false, default: []
      t.jsonb :approvals, null: false, default: []
      t.jsonb :decisions, null: false, default: []
      t.datetime :approved_at
      t.references :approved_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end

    add_index :layered_verification_review_packages, [ :project_id, :package_revision ], unique: true
    add_index :layered_verification_review_packages, :digest

    enable_rls
  end

  def down
    drop_table :layered_verification_review_packages
    drop_table :layered_verification_findings
    drop_table :layered_verification_audits
  end

  private

  # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
  # PostgreSQL row-level security and CREATE POLICY have no equivalent
  # helper, so the SQL stays minimal and isolated to this block. Tenancy is
  # keyed through the project each record belongs to.
  def enable_rls
    safety_assured do
      %i[
        layered_verification_audits
        layered_verification_findings
        layered_verification_review_packages
      ].each do |table|
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
      end

      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_audits
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = layered_verification_audits.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = layered_verification_audits.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL

      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_findings
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = layered_verification_findings.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = layered_verification_findings.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL

      execute <<~SQL
        CREATE POLICY tenant_isolation ON layered_verification_review_packages
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = layered_verification_review_packages.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM projects
              WHERE projects.id = layered_verification_review_packages.project_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL
    end
  end
end
