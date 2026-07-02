# frozen_string_literal: true

class AgentRunResourceProfileRefreshJob < ApplicationJob
  queue_as :default

  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run

    # Refresh recomputes shared fallback profiles, so it must stay outside any
    # per-account tenant scope even if ApplicationJob grows a tenant resolver.
    TenantContext.with_system_access do
      AgentRunResourceProfiles::RefreshForRun.call(agent_run:)
    end
  end
end
