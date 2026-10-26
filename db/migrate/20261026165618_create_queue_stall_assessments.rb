# frozen_string_literal: true

# Durable record of a queue stall assessment: what was detected, which state
# revision it was derived from, and what the recovery attempt did (#4619).
# The (issue, reason, state digest) triple is the dedup key, so an unchanged
# state is never recovered twice.
# @spec QUEUE-DIAG-005 @spec QUEUE-DIAG-012
class CreateQueueStallAssessments < ActiveRecord::Migration[8.1]
  def up
    create_table :queue_stall_assessments,
      comment: "Bounded record of one queue stall assessment: the non-progressing handoff that was " \
        "detected, the state revision it was derived from, and the outcome of the recovery attempt " \
        "(#4619)." do |t|
      t.references :account, null: false, foreign_key: true,
        comment: "Owning tenant. Also the isolation boundary for the assessment."
      t.references :issue, null: false, foreign_key: true,
        comment: "Issue whose delivery handoff stopped progressing."
      t.string :reason_code, null: false,
        comment: "Mechanical stall reason: unseeded_runnable | stale_planning_hold | unresolved_delivery."
      t.string :state_digest, null: false, limit: 64,
        comment: "SHA-256 digest of the relevant state and revisions the assessment was derived from. " \
          "A changed blocker set is a new digest and is assessed again."
      t.string :outcome, null: false, default: "blocked",
        comment: "recovered | blocked | skipped | failed — the outcome of the recovery attempt."
      t.integer :attempt_count, null: false, default: 1,
        comment: "How many times this exact state was assessed. Bounded by the sweep's attempt cap."
      t.text :detail,
        comment: "Operator-visible explanation of the assessment (blockers, owner, next action)."
      t.datetime :assessed_at, null: false,
        comment: "When the assessment was performed."
      t.timestamps
    end

    add_index :queue_stall_assessments, %i[issue_id reason_code state_digest],
      unique: true,
      name: "idx_queue_stall_assessments_one_per_state",
      comment: "Repeated assessment of unchanged state is recorded once and never recovered twice."

    add_index :queue_stall_assessments, %i[account_id assessed_at],
      name: "idx_queue_stall_assessments_account_assessed_at",
      comment: "Supports the account-scoped sweep and the last-successful-assessment lookup."

    enable_rls
  end

  def down
    drop_table :queue_stall_assessments
  end

  private

  # RLS is the documented exception to the Rails-helper rule (AGENTS.md):
  # PostgreSQL row-level security and CREATE POLICY have no equivalent
  # helper, so the SQL stays minimal and isolated to this block. Tenancy is
  # keyed directly through the account column.
  def enable_rls
    safety_assured do
      execute "ALTER TABLE queue_stall_assessments ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE queue_stall_assessments FORCE ROW LEVEL SECURITY"

      execute <<~SQL
        CREATE POLICY tenant_isolation ON queue_stall_assessments
        AS PERMISSIVE
        FOR ALL
        USING (
          paid_tenant_bypass() OR (
            queue_stall_assessments.account_id = paid_current_account_id()
          )
        )
        WITH CHECK (
          paid_tenant_bypass() OR (
            queue_stall_assessments.account_id = paid_current_account_id()
          )
        )
      SQL
    end
  end
end
