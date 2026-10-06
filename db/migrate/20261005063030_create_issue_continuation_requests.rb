# frozen_string_literal: true

# @spec PARTIAL-CLOSEOUT-003 @spec PARTIAL-CLOSEOUT-009
class CreateIssueContinuationRequests < ActiveRecord::Migration[8.1]
  def up
    unless table_exists?(:issue_continuation_requests)
      create_table :issue_continuation_requests, comment: "Scoped authorizations to deliberately continue an issue past prior terminal closeout evidence (merged PR / no-code)." do |t|
        t.references :issue, null: false, foreign_key: true, comment: "The issue whose terminal evidence the request authorizes continuing past."
        t.references :project, null: false, foreign_key: true, comment: "Denormalized project for scoped admission queries; always matches issue.project_id."
        t.references :requested_by, null: false, foreign_key: { to_table: :users }, comment: "Actor who requested the deliberate continuation."
        t.text :reason, null: false, comment: "Required operator/agent justification recorded with the authorization."
        t.jsonb :evidence, null: false, default: {}, comment: "Snapshot of the terminal closeout evidence the request authorizes against (merged PRs, no-code timestamp)."
        t.string :evidence_digest, null: false, comment: "SHA-256 outcome-generation identity; a changed digest supersedes the request."
        t.string :status, null: false, default: "queued", comment: "queued (run in flight) / consumed (run terminal, guards re-armed) / superseded (authorization invalidated)."
        t.datetime :closed_at, comment: "When the request left the open state."
        t.text :closure_reason, comment: "Why the request closed (terminal outcome or supersede reason)."

        t.timestamps
      end
    end

    # One open request per issue: double-clicks, replays, and concurrent
    # requests can queue at most one continuation run (PARTIAL-CLOSEOUT-003).
    unless index_exists?(:issue_continuation_requests, :issue_id, name: "index_issue_continuation_requests_open_per_issue")
      add_index :issue_continuation_requests, :issue_id,
        name: "index_issue_continuation_requests_open_per_issue",
        unique: true,
        where: "status = 'queued'"
    end

    # Plain column without index/FK, matching the agent_runs column
    # precedent (see AddReviewDepthSnapshotToAgentRuns): hot-path table, and
    # the pair is always created in one transaction by
    # Issues::RequestContinuation. The lookup index is added concurrently in
    # AddContinuationRequestIndexToAgentRuns.
    unless column_exists?(:agent_runs, :continuation_request_id)
      add_column :agent_runs, :continuation_request_id, :bigint,
        comment: "The scoped continuation authorization this run executes, if any."
    end

    # Plain columns on the hot issues table (strong_migrations-safe); the
    # closeout_resolved_by_id index is added concurrently in
    # AddCloseoutResolutionColumnsToIssues.
    unless column_exists?(:issues, :closeout_resolved_at)
      add_column :issues, :closeout_resolved_at, :datetime,
        comment: "When an operator resolved this issue as complete against the recorded closeout evidence."
      add_column :issues, :closeout_resolution_digest, :string,
        comment: "Evidence generation the closeout resolution was recorded against; a new generation re-surfaces the lane entry."
      add_column :issues, :closeout_resolved_by_id, :bigint,
        comment: "Operator (users.id) who recorded the closeout resolution."
    end

    safety_assured do
      execute <<~SQL
        ALTER TABLE issue_continuation_requests ENABLE ROW LEVEL SECURITY;
        ALTER TABLE issue_continuation_requests FORCE ROW LEVEL SECURITY;
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1
            FROM pg_policies
            WHERE schemaname = current_schema()
              AND tablename = 'issue_continuation_requests'
              AND policyname = 'tenant_isolation'
          ) THEN
            CREATE POLICY tenant_isolation ON issue_continuation_requests
              AS PERMISSIVE FOR ALL
              USING (
                paid_tenant_bypass() OR EXISTS (
                  SELECT 1 FROM issues
                  INNER JOIN projects ON projects.id = issues.project_id
                  WHERE issues.id = issue_continuation_requests.issue_id
                    AND projects.account_id = paid_current_account_id()
                )
              )
              WITH CHECK (
                paid_tenant_bypass() OR EXISTS (
                  SELECT 1 FROM issues
                  INNER JOIN projects ON projects.id = issues.project_id
                  WHERE issues.id = issue_continuation_requests.issue_id
                    AND projects.account_id = paid_current_account_id()
                )
              );
          END IF;
        END
        $$;
      SQL
    end
  end

  def down
    safety_assured do
      execute "DROP POLICY IF EXISTS tenant_isolation ON issue_continuation_requests"
      execute "ALTER TABLE issue_continuation_requests NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE issue_continuation_requests DISABLE ROW LEVEL SECURITY"
    end

    if column_exists?(:agent_runs, :continuation_request_id)
      remove_column :agent_runs, :continuation_request_id
    end

    if column_exists?(:issues, :closeout_resolved_at)
      remove_column :issues, :closeout_resolved_by_id if column_exists?(:issues, :closeout_resolved_by_id)
      remove_column :issues, :closeout_resolution_digest if column_exists?(:issues, :closeout_resolution_digest)
      remove_column :issues, :closeout_resolved_at
    end

    drop_table :issue_continuation_requests if table_exists?(:issue_continuation_requests)
  end
end
