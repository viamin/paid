# frozen_string_literal: true

module Billing
  class AggregateTenantUsage
    attr_reader :account, :starts_at, :ends_at

    def initialize(account:, starts_at:, ends_at:)
      @account = account
      @starts_at = starts_at
      @ends_at = ends_at
    end

    def self.call(...)
      new(...).call
    end

    def call
      {
        account_id: account.id,
        period: { starts_at: starts_at, ends_at: ends_at },
        token_usage: aggregate_token_usage,
        run_usage: aggregate_run_usage,
        compute_usage: aggregate_compute_usage,
        project_count: active_project_count,
        cost_by_project: cost_by_project
      }
    end

    private

    def project_ids
      @project_ids ||= account.projects.pluck(:id)
    end

    def token_usages_scope
      return TokenUsage.none if project_ids.empty?

      TokenUsage.billable
        .left_outer_joins(:agent_run, :knowledge_run)
        .where(
          "agent_runs.project_id IN (:project_ids) OR knowledge_runs.project_id IN (:project_ids)",
          project_ids: project_ids
        )
        .where(token_usages: { created_at: starts_at..ends_at })
    end

    def aggregate_token_usage
      scope = token_usages_scope
      totals = scope.pick(
        Arel.sql("COALESCE(SUM(token_usages.input_tokens), 0)"),
        Arel.sql("COALESCE(SUM(token_usages.output_tokens), 0)"),
        Arel.sql("COALESCE(SUM(token_usages.cost_cents), 0)")
      ) || [ 0, 0, 0 ]
      {
        total_input_tokens: totals[0],
        total_output_tokens: totals[1],
        total_cost_cents: totals[2],
        by_model: scope.group(:llm_model).sum(:cost_cents),
        by_request_type: scope.group(:request_type).sum(:cost_cents)
      }
    end

    def aggregate_run_usage
      runs = AgentRun.where(project_id: project_ids, created_at: starts_at..ends_at)
      totals = runs.pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'completed')"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'failed')"),
        Arel.sql("COALESCE(SUM(cost_cents), 0)")
      )
      {
        total_runs: totals[0],
        completed_runs: totals[1],
        failed_runs: totals[2],
        total_run_cost_cents: totals[3]
      }
    end

    def aggregate_compute_usage
      metrics = ContainerMetric
        .joins(:agent_run)
        .where(agent_runs: { project_id: project_ids })
        .where(container_metrics: { recorded_at: starts_at..ends_at })

      {
        total_records: metrics.count,
        avg_cpu_percent: metrics.average(:cpu_percent)&.round(2) || 0.0,
        avg_memory_mb: (metrics.average(:memory_bytes) || 0).to_f / (1024 * 1024),
        total_compute_seconds: estimate_compute_seconds(metrics)
      }
    end

    def active_project_count
      account.projects.where(active: true).count
    end

    def cost_by_project
      token_usages_scope
        .group("COALESCE(agent_runs.project_id, knowledge_runs.project_id)")
        .sum(:cost_cents)
    end

    def estimate_compute_seconds(metrics)
      subquery = metrics
        .group("agent_runs.id")
        .select("EXTRACT(EPOCH FROM (MAX(recorded_at) - MIN(recorded_at)))::integer AS duration")

      result = ContainerMetric.from(subquery, :sub).pick(Arel.sql("COALESCE(SUM(sub.duration), 0)"))
      result.to_i
    end
  end
end
