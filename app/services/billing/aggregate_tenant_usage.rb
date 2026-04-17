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
      TokenUsage.billable
        .joins("INNER JOIN agent_runs ON agent_runs.id = token_usages.agent_run_id")
        .where(agent_runs: { project_id: project_ids })
        .where(token_usages: { created_at: starts_at..ends_at })
    end

    def aggregate_token_usage
      scope = token_usages_scope
      {
        total_input_tokens: scope.sum(:input_tokens),
        total_output_tokens: scope.sum(:output_tokens),
        total_cost_cents: scope.sum(:cost_cents),
        by_model: scope.group(:llm_model).sum(:cost_cents),
        by_request_type: scope.group(:request_type).sum(:cost_cents)
      }
    end

    def aggregate_run_usage
      runs = AgentRun.where(project_id: project_ids, created_at: starts_at..ends_at)
      {
        total_runs: runs.count,
        completed_runs: runs.where(status: "completed").count,
        failed_runs: runs.where(status: "failed").count,
        total_run_cost_cents: runs.sum(:cost_cents)
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
        .group("agent_runs.project_id")
        .sum(:cost_cents)
    end

    def estimate_compute_seconds(metrics)
      metrics
        .group("agent_runs.id")
        .select("agent_runs.id, EXTRACT(EPOCH FROM (MAX(recorded_at) - MIN(recorded_at)))::integer AS duration")
        .map { |r| r.duration.to_i }
        .sum
    end
  end
end
