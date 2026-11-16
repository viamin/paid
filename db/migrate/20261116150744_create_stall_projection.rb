# frozen_string_literal: true

# RDR-081 / PARTIAL-CLOSEOUT-042: the persisted, display-only stall read
# model for the partial-closeout Inbox lane. One checkpoint row per project
# records every successful recomputation (including an empty result, so an
# evaluated project with no stalls is distinguishable from an unevaluated
# one); its child rows carry the projected stalls with the display payload
# the lane renders. Nothing here grants admission: live
# `DefaultCandidateSource.eligible_scope` stays the authority at preflight,
# dequeue, and run start, and no project is enrolled by migration (the
# `partial_closeout_lane_read_model` flag is default-off).
class CreateStallProjection < ActiveRecord::Migration[8.1]
  def up
    create_table :stall_projection_checkpoints do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: { to_table: :projects }, index: { unique: true }
      t.datetime :computed_at, comment: "When the last successful projection committed; null until one succeeds."
      t.bigint :generation, null: false, default: 0, comment: "Identity of the last successful atomic replacement."
      t.string :input_watermark, comment: "Newest admission-relevant input digest included in that computation."
      t.datetime :last_failure_at
      t.jsonb :last_failure, null: false, default: {}, comment: "Bounded failure metadata for operator diagnosis."
      t.timestamps
    end

    create_table :stall_projection_stalls do |t|
      t.references :account, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: { to_table: :projects }
      t.references :issue, null: false, foreign_key: { to_table: :issues }
      t.string :evidence_digest, null: false
      t.string :status, null: false, comment: "Recorded outcome label the stall was computed against."
      t.text :reason, null: false, comment: "Why automatic continuation cannot proceed."
      t.jsonb :blockers, null: false, default: [], comment: "Additive structured blockers CloseoutStatus produced."
      t.jsonb :unresolved_prerequisites, null: false, default: []
      t.jsonb :evidence, null: false, default: {}, comment: "Display evidence snapshot: merged PRs, terminal and no-code timestamps, digests."
      t.jsonb :technical_evidence, null: false, default: []
      t.bigint :projection_generation, null: false, comment: "Checkpoint generation that produced this row."
      t.timestamps

      t.index %i[project_id issue_id], unique: true, name: "idx_stall_projection_stalls_project_issue"
      t.index %i[project_id projection_generation], name: "idx_stall_projection_stalls_project_generation"
    end

    enable_tenant_rls(:stall_projection_checkpoints)
    enable_tenant_rls(:stall_projection_stalls)
  end

  def down
    disable_tenant_rls(:stall_projection_stalls)
    disable_tenant_rls(:stall_projection_checkpoints)
    drop_table :stall_projection_stalls
    drop_table :stall_projection_checkpoints
  end

  private

  def enable_tenant_rls(table)
    safety_assured do
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON #{table}
        AS PERMISSIVE
        FOR ALL
        USING (paid_tenant_bypass() OR (#{tenant_condition(table)}))
        WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition(table)}))
      SQL
    end
  end

  def disable_tenant_rls(table)
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
      execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
    end
  end

  def tenant_condition(table)
    <<~SQL.squish
      #{table}.account_id = paid_current_account_id()
      AND EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = #{table}.project_id
          AND projects.account_id = paid_current_account_id()
      )
    SQL
  end
end
