# frozen_string_literal: true

# RDR-081 Option B: persisted, display-only stall projection for the
# partial-closeout Inbox lane. One project checkpoint records every successful
# recomputation (including an empty result), and stalled-issue rows belong to
# that checkpoint. Live admission (`DefaultCandidateSource.eligible_scope`)
# remains the admission authority; the projection never authorizes work.
class CreatePartialCloseoutStallProjections < ActiveRecord::Migration[8.1]
  def up
    create_table :partial_closeout_stall_checkpoints, comment: "Project checkpoint for the display-only partial-closeout stall projection (RDR-081)." do |t|
      t.references :project, null: false, foreign_key: true, index: { unique: true }
      t.datetime :computed_at, comment: "When the last successful projection committed; null until one succeeds."
      t.bigint :generation, comment: "Identity of the last successful atomic replacement."
      t.string :input_watermark, comment: "Digest of the admission-relevant inputs included in the last successful computation."
      t.datetime :last_failure_at
      t.jsonb :last_failure, null: false, default: {}, comment: "Bounded failure metadata for operator diagnosis."
      t.timestamps
    end

    create_table :partial_closeout_stalls, comment: "Projected partial-closeout stall rows owned by a project checkpoint (RDR-081)." do |t|
      t.references :project, null: false, foreign_key: true
      t.references :issue, null: false, foreign_key: true, index: { unique: true }
      t.string :evidence_digest, null: false
      t.jsonb :status, null: false, default: {}, comment: "Recorded outcome, reason, prerequisites, and evidence snapshot for display rehydration."
      t.jsonb :blockers, null: false, default: [], comment: "Additive structured blockers the live CloseoutStatus evaluation produced."
      t.bigint :projection_generation, null: false, comment: "Checkpoint generation that produced the row."
      t.timestamps
    end
    add_index :partial_closeout_stalls, [ :project_id, :projection_generation ],
      name: "index_partial_closeout_stalls_on_project_and_generation"

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :partial_closeout_stalls
    drop_table :partial_closeout_stall_checkpoints
  end

  private

  def enable_tenant_rls
    safety_assured do
      [ :partial_closeout_stall_checkpoints, :partial_closeout_stalls ].each do |table|
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
        execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
        execute "CREATE POLICY tenant_isolation ON #{table} AS PERMISSIVE FOR ALL " \
          "USING (paid_tenant_bypass() OR (#{tenant_condition(table)})) " \
          "WITH CHECK (paid_tenant_bypass() OR (#{tenant_condition(table)}))"
      end
    end
  end

  def disable_tenant_rls
    safety_assured do
      [ :partial_closeout_stall_checkpoints, :partial_closeout_stalls ].each do |table|
        execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
        execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
      end
    end
  end

  def tenant_condition(table)
    project_condition = <<~SQL.squish
      EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = #{table}.project_id
          AND projects.account_id = paid_current_account_id()
      )
    SQL
    return project_condition if table == :partial_closeout_stall_checkpoints

    "#{project_condition} AND #{issue_condition(table)}"
  end

  def issue_condition(table)
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM issues
        INNER JOIN projects AS issue_projects ON issue_projects.id = issues.project_id
        WHERE issues.id = #{table}.issue_id
          AND issues.project_id = #{table}.project_id
          AND issue_projects.account_id = paid_current_account_id()
      )
    SQL
  end
end
