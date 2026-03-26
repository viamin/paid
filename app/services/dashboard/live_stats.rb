# frozen_string_literal: true

module Dashboard
  class LiveStats
    def self.call(...)
      new(...).call
    end

    def initialize(account:)
      @account = account
    end

    def call
      today = Time.current.beginning_of_day
      base = agent_runs

      {
        active_runs: base.where(status: AgentRun::ACTIVE_STATUSES).count,
        queued_runs: base.where(status: "queued").count,
        completed_today: base.where(status: "completed").where(completed_at: today..).count,
        failed_today: base.where(status: FAILURE_STATUSES).where(completed_at: today..).count,
        active_containers: base.where(status: "running").where.not(container_id: nil).count,
        total_projects: account.projects.count,
        active_projects: account.projects.active.count
      }
    end

    FAILURE_STATUSES = %w[failed timeout auth_expired rate_limited].freeze
    private_constant :FAILURE_STATUSES

    private

    attr_reader :account

    def agent_runs
      @agent_runs ||= AgentRun.joins(:project).where(projects: { account_id: account.id })
    end
  end
end
