# frozen_string_literal: true

class LiveDashboardBroadcastJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(account_id, agent_run_id)
    agent_run = AgentRun
      .joins(project: :account)
      .includes(project: :account)
      .find_by!(id: agent_run_id, projects: { account_id: account_id })

    Dashboard::LiveBroadcaster.call(account: agent_run.project.account, agent_run: agent_run)
  end
end
