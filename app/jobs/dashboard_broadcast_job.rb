# frozen_string_literal: true

# Broadcasts dashboard stats to connected Turbo Stream subscribers.
# Enqueued from AgentRun after_commit to avoid blocking the request
# with the aggregate queries in Dashboard::Stats.
class DashboardBroadcastJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :low_priority

  # Coalesce rapid-fire broadcasts for the same account. Only one broadcast
  # per account needs to run at a time; newer enqueues replace stale ones.
  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "dashboard_broadcast_#{arguments.first}" }
  )

  def perform(account_id)
    account = Account.find(account_id)
    Dashboard::Broadcaster.call(account: account)
  end
end
