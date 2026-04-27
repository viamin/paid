# frozen_string_literal: true

module Knowledge
  class DashboardStats
    attr_reader :account

    def initialize(account:)
      @account = account
    end

    def self.call(...)
      new(...).call
    end

    def call
      {
        projects_indexed: projects_indexed,
        projects_total: projects_total,
        total_artifacts: total_artifacts,
        stale_artifacts: stale_artifacts,
        stale_percent: stale_percent,
        artifacts_by_type: artifacts_by_type,
        last_collection_at: last_collection_at,
        token_usage_summary: token_usage_summary,
        knowledge_usage_summary: knowledge_usage_summary,
        usage_by_goal: usage_by_goal
      }
    end

    private

    def artifacts
      @artifacts ||= KnowledgeArtifact
        .joins(:project)
        .where(projects: { account_id: account.id })
    end

    def projects_total
      @projects_total ||= Project.where(account_id: account.id).count
    end

    def projects_indexed
      @projects_indexed ||= artifacts.where.not(status: "deleted")
        .select(:project_id).distinct.count
    end

    def total_artifacts
      @total_artifacts ||= artifacts.active.count
    end

    def stale_artifacts
      @stale_artifacts ||= artifacts.stale.count
    end

    def stale_percent
      total = total_artifacts + stale_artifacts
      return 0 if total.zero?

      ((stale_artifacts.to_f / total) * 100).round
    end

    def artifacts_by_type
      @artifacts_by_type ||= artifacts.active.group(:artifact_type).count
        .sort_by { |_, v| -v }
    end

    def last_collection_at
      @last_collection_at ||= CollectorRun
        .joins(project_version: :project)
        .where(projects: { account_id: account.id })
        .where(status: "completed")
        .maximum(:completed_at)
    end

    def token_usage_summary
      @token_usage_summary ||= knowledge_runs
        .group(:operation_type)
        .pluck(
          Arel.sql("operation_type"),
          Arel.sql("SUM(total_tokens)"),
          Arel.sql("COUNT(*)")
        )
        .map { |op, tokens, count| { operation_type: op, total_tokens: tokens.to_i, run_count: count.to_i } }
    end

    def knowledge_runs
      KnowledgeRun.joins(:project)
        .where(projects: { account_id: account.id })
    end

    def knowledge_usage_summary
      @knowledge_usage_summary ||= KnowledgeUsageStat
        .joins(:project)
        .where(projects: { account_id: account.id })
        .group(:artifact_type)
        .sum(:artifact_count)
        .sort_by { |_, v| -v }
    end

    def usage_by_goal
      @usage_by_goal ||= KnowledgeUsageStat
        .joins(:project)
        .where(projects: { account_id: account.id })
        .group(:goal)
        .sum(:artifact_count)
        .sort_by { |_, v| -v }
    end
  end
end
