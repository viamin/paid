# frozen_string_literal: true

class AgentRunResourceProfileRefreshJob < ApplicationJob
  queue_as :default

  # @spec RAILS-CONTROL-PLANE-012
  def perform(agent_run_id, profile_level: AgentRunResourceProfiles::RefreshForRun::PROFILE_LEVELS.first)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run

    # Refresh recomputes shared fallback profiles, so it must stay outside any
    # per-account tenant scope even if ApplicationJob grows a tenant resolver.
    refreshed = TenantContext.with_system_access do
      AgentRunResourceProfiles::RefreshForRun.call(agent_run:, profile_level:)
    end
    return unless refreshed

    levels = AgentRunResourceProfiles::RefreshForRun::PROFILE_LEVELS
    index = levels.index(profile_level)
    return unless index

    next_level = levels[index + 1]
    self.class.perform_later(agent_run_id, profile_level: next_level) if next_level
  end
end
