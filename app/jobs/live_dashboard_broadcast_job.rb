# frozen_string_literal: true

class LiveDashboardBroadcastJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :low_priority
  discard_on ActiveRecord::RecordNotFound

  # Coalesce rapid-fire broadcasts for the same agent run. Only the latest
  # state matters, so at most one broadcast per run should be in-flight.
  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "live_dashboard_broadcast_#{arguments[1]}" }
  )

  def perform(account_id, agent_run_id)
    agent_run = AgentRun
      .joins(project: :account)
      .includes(project: :account)
      .find_by!(id: agent_run_id, projects: { account_id: account_id })

    Dashboard::LiveBroadcaster.call(account: agent_run.project.account, agent_run: agent_run)
  end
end
