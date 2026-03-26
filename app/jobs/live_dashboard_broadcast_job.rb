# frozen_string_literal: true

class LiveDashboardBroadcastJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(account_id, agent_run_id)
    account = Account.find(account_id)
    agent_run = AgentRun.find(agent_run_id)

    Dashboard::LiveBroadcaster.call(account: account, agent_run: agent_run)
  end
end
