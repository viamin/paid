# frozen_string_literal: true

module Dashboard
  class RecentActivity
    DEFAULT_LIMIT = 10

    def self.call(...)
      new(...).call
    end

    def initialize(account:, limit: DEFAULT_LIMIT)
      @account = account
      @limit = limit
    end

    def call
      (recent_agent_runs + recent_merged_prs)
        .sort_by { |item| -item_timestamp(item).to_i }
        .first(limit)
    end

    private

    attr_reader :account, :limit

    def recent_agent_runs
      AgentRun.joins(:project)
        .where(projects: { account_id: account.id })
        .finished
        .includes(:project, :issue)
        .order(Arel.sql("COALESCE(agent_runs.completed_at, agent_runs.created_at) DESC"))
        .limit(limit)
        .to_a
    end

    def recent_merged_prs
      Issue.joins(:project)
        .where(projects: { account_id: account.id })
        .where(is_pull_request: true, pr_review_phase: "merged")
        .includes(:project)
        .order(github_updated_at: :desc)
        .limit(limit)
        .to_a
    end

    def item_timestamp(item)
      case item
      when AgentRun then item.completed_at || item.created_at
      when Issue    then item.github_updated_at
      end
    end
  end
end
