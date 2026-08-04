# frozen_string_literal: true

module Knowledge
  class UsageStats
    # @spec KNOWLEDGE-005
    attr_reader :project, :since

    def initialize(project:, since: 30.days.ago)
      @project = project
      @since = since
    end

    def usage_by_artifact_type(goal: nil)
      scope = base_scope
      scope = scope.by_goal(goal) if goal
      scope.group(:artifact_type).sum(:artifact_count)
    end

    def usage_by_goal
      base_scope.group(:goal).sum(:artifact_count)
    end

    def effectiveness_by_artifact_type
      rows = KnowledgeUsageStat
        .joins(:agent_run)
        .where(project: project)
        .where(created_at: since..)
        .group(:artifact_type)
        .pluck(
          Arel.sql("knowledge_usage_stats.artifact_type"),
          Arel.sql("COUNT(DISTINCT knowledge_usage_stats.agent_run_id)"),
          Arel.sql("COUNT(DISTINCT CASE WHEN agent_runs.status = 'completed' THEN agent_runs.id END)")
        )

      rows.to_h do |type, total, succeeded|
        rate = total.positive? ? (succeeded.to_f / total * 100).round(1) : 0.0
        [ type, { total_runs: total, successful_runs: succeeded, success_rate: rate } ]
      end
    end

    def top_artifact_types(limit: 10)
      usage_by_artifact_type.sort_by { |_, v| -v }.first(limit)
    end

    def least_used_artifact_types(limit: 10)
      usage_by_artifact_type.sort_by { |_, v| v }.first(limit)
    end

    def usage_by_context_type
      base_scope.group(:context_type).sum(:artifact_count)
    end

    private

    def base_scope
      scope = KnowledgeUsageStat.since(since)
      scope = scope.for_project(project) if project
      scope
    end
  end
end
