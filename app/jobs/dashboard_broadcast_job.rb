# frozen_string_literal: true

# Broadcasts dashboard stats to connected Turbo Stream subscribers.
# Enqueued from AgentRun after_commit to avoid blocking the request
# with the aggregate queries in Dashboard::Stats.
class DashboardBroadcastJob < ApplicationJob
  queue_as :default

  def perform(account_id)
    account = Account.find(account_id)
    Dashboard::Broadcaster.call(account: account)
  end
end
