# frozen_string_literal: true

module Dashboard
  class RecentActivity
    DEFAULT_LIMIT = 10
    CACHE_TTL = 15.seconds

    def self.call(...)
      new(...).call
    end

    def initialize(account:, limit: DEFAULT_LIMIT)
      @account = account
      @limit = limit
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build_items }
    end

    private

    attr_reader :account, :limit

    def build_items
      (recent_agent_runs + recent_merged_prs + recent_quality_pause_events)
        .sort_by { |item| -item_timestamp(item).to_i }
        .first(limit)
    end

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

    def recent_quality_pause_events
      QualityPauseEvent.joins(:project)
        .where(projects: { account_id: account.id })
        .includes(:project)
        .recent
        .limit(limit)
        .to_a
    end

    def item_timestamp(item)
      case item
      when AgentRun then item.completed_at || item.created_at
      when Issue    then item.github_updated_at
      when QualityPauseEvent then item.created_at
      end
    end

    def cache_key
      "dashboard/recent_activity/#{account.id}/#{limit}/#{Dashboard::CacheVersion.current(account, scope: Dashboard::CacheVersion::LISTS_SCOPE)}"
    end
  end
end
