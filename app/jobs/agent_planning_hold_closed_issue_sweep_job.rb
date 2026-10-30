# frozen_string_literal: true

# Bounded backstop that clears stale "Planning hold needs reconciliation"
# Inbox notifications for already-closed issues — both the pre-existing
# backlog recorded before Issue#reconcile_agent_planning_holds_on_close
# existed, and any missed close event (e.g. a webhook gap). The hook on Issue
# covers the normal path; this job only re-reads persisted holds, across
# every tenant, so no account depends on this sweep running on its own
# schedule.
# @spec CONFIDENCE-DELIVERY-019
class AgentPlanningHoldClosedIssueSweepJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "agent_planning_hold_closed_issue_sweep"
  )

  def perform
    reconciled_count = AgentPlanningHolds::SweepClosedIssues.call

    Rails.logger.info(
      message: "agent_planning_holds.closed_issue_sweep_completed",
      reconciled_count: reconciled_count
    )
  end
end
