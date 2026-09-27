# frozen_string_literal: true

# @spec INTENT-CONFORMANCE-010 @spec INTENT-CONFORMANCE-011
class CreateIntentConformanceReviewSchedules < ActiveRecord::Migration[8.1]
  def up
    create_table :intent_conformance_review_schedules,
      comment: "Durable review schedules de-duplicating independent intent-conformance review runs per " \
        "(issue, PR HEAD SHA, approved design revision) identity (RDR-067 #4050). Exactly one review chain " \
        "(including bounded transient retries) runs per identity." do |t|
      t.references :project, null: false, foreign_key: true, comment: "Project whose pull request is reviewed."
      t.references :issue, null: false, foreign_key: true,
        comment: "The pull request (Issue row) the independent review targets."
      t.string :pr_head_sha, null: false, limit: 40,
        comment: "PR HEAD commit SHA the review is de-duplicated against; a new head schedules a fresh review."
      t.string :approved_design_revision, null: false,
        comment: "Approved design revision the review is de-duplicated against; a re-approved revision schedules a fresh review."
      t.string :status, null: false, default: "pending",
        comment: "pending while the review chain (including retries) is active; completed once terminal (see IntentConformanceReviewSchedule::STATUSES)."
      t.integer :attempts_count, null: false, default: 0,
        comment: "Review attempts executed for this schedule, including transient retries."
      t.string :last_failure_reason,
        comment: "Classified failure reason recorded when the schedule completed without a terminal reviewer outcome."
      t.datetime :enqueued_at, comment: "When the review job was last enqueued; a stale value allows lost-job recovery."
      t.datetime :completed_at, comment: "When the schedule reached its terminal status."
      t.timestamps
    end

    add_index :intent_conformance_review_schedules,
      %i[issue_id pr_head_sha approved_design_revision],
      unique: true,
      name: "idx_intent_review_schedules_unique_identity",
      comment: "Repeated scans of the same (pull request, PR head, approved design revision) never spawn a second review chain."
    add_index :intent_conformance_review_schedules, %i[project_id status],
      name: "idx_intent_review_schedules_project_status",
      comment: "Backs the bounded per-project pending-schedule check."

    enable_rls
  end

  def down
    drop_table :intent_conformance_review_schedules
  end

  private

  # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
  # PostgreSQL row-level security and CREATE POLICY have no equivalent
  # helper, so the SQL stays minimal and isolated to this block. Tenancy is
  # keyed through the schedule's issue, mirroring intent_conformance_verdicts.
  def enable_rls
    safety_assured do
      execute "ALTER TABLE intent_conformance_review_schedules ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE intent_conformance_review_schedules FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY tenant_isolation ON intent_conformance_review_schedules
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM issues
              INNER JOIN projects ON projects.id = issues.project_id
              WHERE issues.id = intent_conformance_review_schedules.issue_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            EXISTS (
              SELECT 1 FROM issues
              INNER JOIN projects ON projects.id = issues.project_id
              WHERE issues.id = intent_conformance_review_schedules.issue_id
                AND projects.account_id = paid_current_account_id()
            )
          )
        )
      SQL
    end
  end
end
