# frozen_string_literal: true

module Dashboard
  class LiveStats
    attr_reader :account

    def initialize(account:)
      @account = account
    end

    def self.call(...)
      new(...).call
    end

    def call
      {
        active_runs: agent_runs.active.count,
        queued_runs: agent_runs.queued.count,
        completed_today: agent_runs.completed.where(completed_at: Time.current.beginning_of_day..).count,
        failed_today: agent_runs.failed.where(completed_at: Time.current.beginning_of_day..).count,
        active_containers: agent_runs.running.where.not(container_id: nil).count,
        total_projects: account.projects.count,
        active_projects: account.projects.active.count
      }
    end

    private

    def agent_runs
      @agent_runs ||= AgentRun.joins(:project).where(projects: { account_id: account.id })
    end
  end
end
