# frozen_string_literal: true

# Adds the persisted state for the awaiting_approval escalation: the
# per-project ceiling (pr_approval_escalation_hours) and the per-PR wait
# origin stamp (issues.awaiting_approval_since).
class AddApprovalWaitEscalationToIssuesAndProjects < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:projects, :pr_approval_escalation_hours)
      add_column :projects, :pr_approval_escalation_hours, :integer, default: 24, null: false,
        comment: "Hours a ready PR may sit green and blocked only on owner approval before escalating; 0 disables the awaiting_approval escalation."
    end

    return if column_exists?(:issues, :awaiting_approval_since)

    add_column :issues, :awaiting_approval_since, :datetime,
      comment: "When the scan first observed this PR green and blocked only on owner approval; cleared whenever a non-approval blocker appears. Drives the awaiting_approval escalation ceiling."
  end
end
