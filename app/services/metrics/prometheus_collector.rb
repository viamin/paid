# frozen_string_literal: true

module Metrics
  # Collects application metrics and renders them in Prometheus text exposition format.
  # Used by the /api/metrics endpoint to feed external auto-scaling systems.
  class PrometheusCollector
    DURATION_BUCKETS = [ 30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200 ].freeze
    RUN_OUTCOMES = %w[success failure].freeze

    def self.call # @spec OBSERVABILITY-002
      Rails.cache.fetch("prometheus_metrics", expires_in: 15.seconds) do
        new.call
      end
    end

    def call
      lines = []
      collect_agent_run_metrics(lines)
      collect_good_job_metrics(lines)
      collect_container_metrics(lines)
      collect_container_pool_metrics(lines)
      collect_service_container_metrics(lines)
      collect_temporal_config_metrics(lines)
      lines.join("\n") + "\n"
    end

    private

    def collect_agent_run_metrics(lines)
      counts = AgentRun.group(:status).count

      append_metric_header(lines, "paid_agent_runs_total", "gauge", "Number of agent runs by status.")
      AgentRun::STATUSES.each do |status|
        append_metric_sample(lines, "paid_agent_runs_total", counts.fetch(status) { 0 }, status: status)
      end

      active = counts.values_at(*AgentRun::ACTIVE_STATUSES).compact.sum
      append_metric_header(lines, "paid_agent_runs_active", "gauge", "Currently active agent runs.")
      append_metric_sample(lines, "paid_agent_runs_active", active)

      queued = AgentRun.waiting.count
      append_metric_header(lines, "paid_agent_runs_queued", "gauge", "Agent runs waiting in queue.")
      append_metric_sample(lines, "paid_agent_runs_queued", queued)

      collect_agent_run_outcome_metrics(lines)
      collect_agent_run_duration_histogram(lines)
      collect_agent_run_token_metrics(lines)
      collect_agent_run_cost_metrics(lines)
    end

    def collect_good_job_metrics(lines)
      queue_counts = GoodJob::Job.where(finished_at: nil)
                                 .group(:queue_name)
                                 .count

      append_metric_header(lines, "paid_goodjob_queue_depth", "gauge", "Number of unfinished jobs per queue.")
      queue_counts.each do |queue, count|
        append_metric_sample(lines, "paid_goodjob_queue_depth", count, queue: queue)
      end

      total_unfinished = queue_counts.values.sum
      append_metric_header(lines, "paid_goodjob_jobs_unfinished", "gauge", "Total unfinished GoodJob jobs.")
      append_metric_sample(lines, "paid_goodjob_jobs_unfinished", total_unfinished)

      running = GoodJob::Job.where.not(performed_at: nil).where(finished_at: nil).count
      errored = GoodJob::Job.where.not(error: nil).where(finished_at: nil).count

      append_metric_header(lines, "paid_goodjob_jobs_running", "gauge", "GoodJob jobs currently executing.")
      append_metric_sample(lines, "paid_goodjob_jobs_running", running)

      append_metric_header(lines, "paid_goodjob_jobs_errored", "gauge", "GoodJob jobs in error state.")
      append_metric_sample(lines, "paid_goodjob_jobs_errored", errored)
    end

    def collect_container_metrics(lines)
      active_runs = AgentRun.where(status: AgentRun::ACTIVE_STATUSES)
                            .where.not(container_id: [ nil, "" ])

      append_metric_header(lines, "paid_containers_active", "gauge", "Containers running agent work.")
      append_metric_sample(lines, "paid_containers_active", active_runs.distinct.count(:container_id))

      latest_metrics = ContainerMetric
        .where(agent_run_id: active_runs.select(:id))
        .where(recorded_at: 5.minutes.ago..)
        .select("DISTINCT ON (container_id) container_id, cpu_percent, memory_bytes, memory_limit_bytes, memory_percent")
        .order(:container_id, recorded_at: :desc)

      if latest_metrics.any?
        avg_cpu = latest_metrics.sum(&:cpu_percent) / latest_metrics.size
        avg_mem = latest_metrics.sum(&:memory_percent) / latest_metrics.size
        total_memory_bytes = latest_metrics.sum(&:memory_bytes)

        append_metric_header(lines, "paid_containers_avg_cpu_percent", "gauge", "Average CPU usage across active containers.")
        append_metric_sample(lines, "paid_containers_avg_cpu_percent", avg_cpu.round(2))

        append_metric_header(lines, "paid_containers_avg_memory_percent", "gauge", "Average memory usage across active containers.")
        append_metric_sample(lines, "paid_containers_avg_memory_percent", avg_mem.round(2))

        append_metric_header(lines, "paid_containers_total_memory_bytes", "gauge", "Total memory used by active containers.")
        append_metric_sample(lines, "paid_containers_total_memory_bytes", total_memory_bytes)
      end
    end

    def collect_container_pool_metrics(lines)
      status_counts = ContainerPoolEntry.group(:status).count

      append_metric_header(lines, "paid_container_pool_entries_total", "gauge", "Warm container pool entries by status.")
      ContainerPoolEntry::STATUSES.each do |status|
        append_metric_sample(lines, "paid_container_pool_entries_total", status_counts.fetch(status) { 0 }, status: status)
      end

      target = Containers::PoolManager.effective_target_size(projects: Project.active)
      append_metric_header(lines, "paid_container_pool_target", "gauge", "Target warm container pool size.")
      append_metric_sample(lines, "paid_container_pool_target", target)
    end

    def collect_service_container_metrics(lines)
      status_counts = ServiceContainer.group(:status).count

      append_metric_header(lines, "paid_service_containers_total", "gauge", "Service containers by status.")
      ServiceContainer::STATUSES.each do |status|
        append_metric_sample(lines, "paid_service_containers_total", status_counts.fetch(status) { 0 }, status: status)
      end

      running_ids = ServiceContainer.where(status: "running").select(:id)
      latest_svc_metrics = ServiceContainerMetric
        .where(service_container_id: running_ids)
        .where(recorded_at: 5.minutes.ago..)
        .select("DISTINCT ON (service_container_id) service_container_id, cpu_percent, memory_bytes, memory_percent")
        .order(:service_container_id, recorded_at: :desc)

      if latest_svc_metrics.any?
        append_metric_header(lines, "paid_service_containers_avg_cpu_percent", "gauge", "Average CPU across running service containers.")
        avg_cpu = latest_svc_metrics.sum(&:cpu_percent) / latest_svc_metrics.size
        append_metric_sample(lines, "paid_service_containers_avg_cpu_percent", avg_cpu.round(2))

        append_metric_header(lines, "paid_service_containers_avg_memory_percent", "gauge", "Average memory across running service containers.")
        avg_mem = latest_svc_metrics.sum(&:memory_percent) / latest_svc_metrics.size
        append_metric_sample(lines, "paid_service_containers_avg_memory_percent", avg_mem.round(2))
      end
    end

    def collect_temporal_config_metrics(lines)
      workflow_slots = resolve_worker_setting("temporal_workflow_slots", "TEMPORAL_WORKFLOW_SLOTS", 20)
      activity_slots = resolve_worker_setting("temporal_activity_slots", "TEMPORAL_ACTIVITY_SLOTS", 4)

      append_metric_header(lines, "paid_temporal_workflow_slots_total", "gauge", "Configured Temporal workflow slots.")
      append_metric_sample(lines, "paid_temporal_workflow_slots_total", workflow_slots)

      append_metric_header(lines, "paid_temporal_activity_slots_total", "gauge", "Configured Temporal activity slots.")
      append_metric_sample(lines, "paid_temporal_activity_slots_total", activity_slots)

      running_workflows = AgentRun.running.where.not(temporal_workflow_id: [ nil, "" ]).count
      append_metric_header(lines, "paid_temporal_workflows_running", "gauge", "Temporal workflows currently running.")
      append_metric_sample(lines, "paid_temporal_workflows_running", running_workflows)

      utilization = if workflow_slots.positive?
        (running_workflows.to_f / workflow_slots * 100).round(2)
      else
        0.0
      end
      append_metric_header(lines, "paid_temporal_workflow_utilization_percent", "gauge", "Workflow slot utilization percentage.")
      append_metric_sample(lines, "paid_temporal_workflow_utilization_percent", utilization)
    end

    def resolve_worker_setting(key, env_key, default)
      TenantSetting.resolve_worker_setting(key, env_key: env_key, env: ENV, default: default)
    end

    def collect_agent_run_outcome_metrics(lines)
      outcome_counts = finished_run_counts_by_status

      append_metric_header(lines, "paid_agent_run_outcomes_total", "counter", "Total finished agent runs by terminal status and normalized outcome.")
      AgentRun::FINISHED_STATUSES.each do |status|
        append_metric_sample(
          lines,
          "paid_agent_run_outcomes_total",
          outcome_counts.fetch(status) { 0 },
          status: status,
          outcome: normalized_outcome_for(status)
        )
      end
    end

    def collect_agent_run_duration_histogram(lines)
      duration_counts = finished_run_durations_by_status

      append_metric_header(lines, "paid_agent_run_duration_seconds", "histogram", "Finished agent run durations in seconds by normalized outcome.")
      RUN_OUTCOMES.each do |outcome|
        cumulative = 0
        grouped_counts = duration_counts.fetch(outcome) { Hash.new(0) }

        DURATION_BUCKETS.each do |bucket|
          cumulative += grouped_counts.fetch(bucket, 0)
          append_metric_sample(lines, "paid_agent_run_duration_seconds_bucket", cumulative, outcome: outcome, le: bucket)
        end

        total_count = grouped_counts.values.sum
        append_metric_sample(lines, "paid_agent_run_duration_seconds_bucket", total_count, outcome: outcome, le: "+Inf")
        append_metric_sample(lines, "paid_agent_run_duration_seconds_sum", finished_run_duration_sums.fetch(outcome) { 0 }, outcome: outcome)
        append_metric_sample(lines, "paid_agent_run_duration_seconds_count", total_count, outcome: outcome)
      end
    end

    def collect_agent_run_token_metrics(lines)
      append_metric_header(lines, "paid_agent_run_tokens_total", "counter", "Total finished agent-run tokens by direction and normalized outcome.")

      RUN_OUTCOMES.each do |outcome|
        append_metric_sample(lines, "paid_agent_run_tokens_total", finished_run_input_token_sums.fetch(outcome) { 0 }, direction: "input", outcome: outcome)
        append_metric_sample(lines, "paid_agent_run_tokens_total", finished_run_output_token_sums.fetch(outcome) { 0 }, direction: "output", outcome: outcome)
      end
    end

    def collect_agent_run_cost_metrics(lines)
      append_metric_header(lines, "paid_agent_run_cost_cents_total", "counter", "Total finished agent-run cost in cents by normalized outcome.")

      RUN_OUTCOMES.each do |outcome|
        append_metric_sample(lines, "paid_agent_run_cost_cents_total", finished_run_cost_sums.fetch(outcome) { 0 }, outcome: outcome)
      end
    end

    def finished_run_scope
      AgentRun.where(status: AgentRun::FINISHED_STATUSES)
    end

    def finished_run_counts_by_status
      @finished_run_counts_by_status ||= finished_run_scope.group(:status).count
    end

    def finished_run_durations_by_status
      @finished_run_durations_by_status ||= begin
        bucketed = RUN_OUTCOMES.to_h { |outcome| [ outcome, Hash.new(0) ] }

        finished_run_scope.where.not(duration_seconds: nil).group(:status, :duration_seconds).count.each do |(status, duration), count|
          bucket = DURATION_BUCKETS.find { |threshold| duration <= threshold }
          bucketed[normalized_outcome_for(status)][bucket || :overflow] += count
        end

        bucketed
      end
    end

    def finished_run_duration_sums
      @finished_run_duration_sums ||= aggregate_finished_run_sum(:duration_seconds)
    end

    def finished_run_input_token_sums
      @finished_run_input_token_sums ||= aggregate_finished_run_sum(:tokens_input)
    end

    def finished_run_output_token_sums
      @finished_run_output_token_sums ||= aggregate_finished_run_sum(:tokens_output)
    end

    def finished_run_cost_sums
      @finished_run_cost_sums ||= aggregate_finished_run_sum(:cost_cents)
    end

    def aggregate_finished_run_sum(column)
      sums_by_status = finished_run_scope.group(:status).sum(column)
      RUN_OUTCOMES.to_h do |outcome|
        total = AgentRun::FINISHED_STATUSES.sum do |status|
          normalized_outcome_for(status) == outcome ? sums_by_status.fetch(status, 0).to_i : 0
        end
        [ outcome, total ]
      end
    end

    def normalized_outcome_for(status)
      status == "completed" ? "success" : "failure"
    end

    def append_metric_header(lines, name, type, help)
      lines << "# HELP #{name} #{help}"
      lines << "# TYPE #{name} #{type}"
    end

    def append_metric_sample(lines, name, value, labels = {})
      lines << if labels.any?
        "#{name}{#{format_labels(labels)}} #{value}"
      else
        "#{name} #{value}"
      end
    end

    def format_labels(labels)
      labels.map { |key, value| %(#{key}="#{value}") }.join(",")
    end
  end
end
