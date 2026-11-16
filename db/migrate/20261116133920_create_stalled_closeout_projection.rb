# frozen_string_literal: true

# RDR-081 Option B read model (#4912): the persisted, display-only stall
# projection the partial-closeout Inbox lane reads instead of evaluating
# live admission on the request path. One checkpoint row per project records
# every successful recomputation — including an empty result — and child
# rows carry each stalled issue's recorded outcome and blockers. Live
# `DefaultCandidateSource.eligible_scope` stays the admission authority;
# these tables only describe what that authority decided, last time it was
# asked, outside rendering.
class CreateStalledCloseoutProjection < ActiveRecord::Migration[8.1]
  def up
    create_table :stalled_closeout_projection_checks do |t|
      t.references :project, null: false, foreign_key: { validate: false }, index: { unique: true }
      t.datetime :computed_at, comment: "When the last successful projection was committed; null until one succeeds."
      t.bigint :generation, null: false, default: 0,
        comment: "Identity of the last successful atomic row replacement."
      t.datetime :input_watermark, comment: "Newest admission-relevant input included in that computation."
      t.datetime :last_failure_at, comment: "When the latest failed recomputation attempt occurred, if any."
      t.jsonb :last_failure, null: false, default: {},
        comment: "Bounded failure metadata (error class and message) for operator diagnosis."
      t.timestamps
    end

    create_table :stalled_closeout_projection_rows do |t|
      t.references :project, null: false, foreign_key: { validate: false }
      t.references :issue, null: false, foreign_key: { validate: false }, index: { unique: true }
      t.string :evidence_digest, null: false, comment: "Outcome-generation digest the stall was computed against."
      t.jsonb :status, null: false, default: {},
        comment: "Recorded outcome and reason continuation cannot proceed (serialized CloseoutStatus result)."
      t.jsonb :blockers, null: false, default: [],
        comment: "Additive structured blockers CloseoutStatus produces."
      t.bigint :projection_generation, null: false, comment: "Checkpoint generation that produced the row."
      t.timestamps
    end
    add_index :stalled_closeout_projection_rows, [ :project_id, :projection_generation ],
      name: "idx_stalled_closeout_rows_project_generation"

    enable_tenant_rls
  end

  def down
    disable_tenant_rls
    drop_table :stalled_closeout_projection_rows
    drop_table :stalled_closeout_projection_checks
  end

  private

  def enable_tenant_rls
    tenant_conditions.each do |table, condition|
      safety_assured do
        execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
        execute <<~SQL
          CREATE POLICY tenant_isolation ON #{table}
            AS PERMISSIVE FOR ALL
            USING (paid_tenant_bypass() OR (#{condition}))
            WITH CHECK (paid_tenant_bypass() OR (#{condition}))
        SQL
      end
    end
  end

  def disable_tenant_rls
    %w[stalled_closeout_projection_rows stalled_closeout_projection_checks].each do |table|
      safety_assured do
        execute "DROP POLICY IF EXISTS tenant_isolation ON #{table}"
        execute "ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY"
        execute "ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY"
      end
    end
  end

  def tenant_conditions
    {
      "stalled_closeout_projection_checks" => <<~SQL.squish,
        EXISTS (
          SELECT 1 FROM projects
          WHERE projects.id = stalled_closeout_projection_checks.project_id
            AND projects.account_id = paid_current_account_id()
        )
      SQL
      "stalled_closeout_projection_rows" => <<~SQL.squish
        EXISTS (
          SELECT 1 FROM projects
          WHERE projects.id = stalled_closeout_projection_rows.project_id
            AND projects.account_id = paid_current_account_id()
        )
        AND EXISTS (
          SELECT 1 FROM issues
          WHERE issues.id = stalled_closeout_projection_rows.issue_id
            AND issues.project_id = stalled_closeout_projection_rows.project_id
        )
      SQL
    }
  end
end
