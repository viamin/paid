# frozen_string_literal: true

module Metrics
  # Collects application metrics and renders them in Prometheus text exposition format.
  # Used by the /api/metrics endpoint to feed external auto-scaling systems.
  #
  # DESIGN NOTE — sliding-window gauges, not monotonic counters:
  # The finished-run metrics (outcomes, duration, tokens, cost) are derived from a
  # 6-hour SQL window (FINISHED_RUN_WINDOW). Each scrape queries the DB directly and
  # emits the current snapshot as gauges, not as ever-increasing counters. Values can
  # drop when runs age past the window boundary. These metrics must NOT be used with
  # PromQL rate()/increase() or cumulative-histogram operations (histogram_quantile
  # on rate()-fed data). The _window suffix signals this semantic contract.
  #
  # Replica awareness: /api/metrics is a database-backed snapshot — every web replica
  # exports the same values. Any PromQL aggregator across replicas should use
  # max without(instance, pod, job) (or equivalent) to avoid multiplying values by
  # replica count. Do NOT use sum(...) on these metrics in alert rules or dashboards.
  class PrometheusCollector
    DURATION_BUCKETS = [ 30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200 ].freeze
    FINISHED_RUN_WINDOW = 6.hours.freeze
    RUN_OUTCOMES = %w[success failure non_provider].freeze
    RUN_OUTCOME_METRIC = "paid_agent_run_outcomes_window".freeze
    RUN_DURATION_BUCKET_METRIC = "paid_agent_run_duration_seconds_bucket_window".freeze
    RUN_DURATION_SUM_METRIC = "paid_agent_run_duration_seconds_sum_window".freeze
    RUN_DURATION_COUNT_METRIC = "paid_agent_run_duration_seconds_count_window".freeze
    RUN_TOKEN_METRIC = "paid_agent_run_tokens_window".freeze
    RUN_COST_METRIC = "paid_agent_run_cost_cents_window".freeze

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
      collect_capacity_metrics(lines)
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
      collect_agent_run_duration_metrics(lines)
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

    def collect_capacity_metrics(lines)
      admission_snapshot = Capacity::AdmissionSnapshot.capture(
        window_seconds: Capacity::InfrastructureLimits.current[:provisioning_rate_window_seconds]
      )
      global_active = AgentRun.active_count_global
      global_limit = Capacity::GlobalLimit.max_concurrent_executions
      global_requested = admission_snapshot.global_requested_resources
      global_infra_limits = Capacity::InfrastructureLimits.current
      registry = Containers.host_registry

      append_metric_header(lines, "paid_capacity_global_concurrent_executions", "gauge", "Currently capacity-inflight agent runs across all accounts, hosts, and projects.")
      append_metric_sample(lines, "paid_capacity_global_concurrent_executions", global_active)

      append_metric_header(lines, "paid_capacity_global_concurrent_limit", "gauge", "Configured global concurrent execution limit (MAX_GLOBAL_CONCURRENT_EXECUTIONS).")
      append_metric_sample(lines, "paid_capacity_global_concurrent_limit", global_limit)

      append_metric_header(lines, "paid_capacity_global_requested_cpu_quota", "gauge", "Currently requested CPU quota across capacity-inflight runs.")
      append_metric_sample(lines, "paid_capacity_global_requested_cpu_quota", global_requested[:cpu_quota])
      append_metric_header(lines, "paid_capacity_global_requested_cpu_quota_limit", "gauge", "Configured global requested CPU quota ceiling.")
      append_metric_sample(lines, "paid_capacity_global_requested_cpu_quota_limit", global_infra_limits[:global_requested_cpu_quota_limit])

      append_metric_header(lines, "paid_capacity_global_requested_memory_bytes", "gauge", "Currently requested memory bytes across capacity-inflight runs.")
      append_metric_sample(lines, "paid_capacity_global_requested_memory_bytes", global_requested[:memory_bytes])
      append_metric_header(lines, "paid_capacity_global_requested_memory_bytes_limit", "gauge", "Configured global requested memory ceiling.")
      append_metric_sample(lines, "paid_capacity_global_requested_memory_bytes_limit", global_infra_limits[:global_requested_memory_bytes_limit])

      append_metric_header(lines, "paid_capacity_global_requested_disk_bytes", "gauge", "Currently requested disk bytes across capacity-inflight runs.")
      append_metric_sample(lines, "paid_capacity_global_requested_disk_bytes", global_requested[:disk_bytes])
      append_metric_header(lines, "paid_capacity_global_requested_disk_bytes_limit", "gauge", "Configured global requested disk ceiling.")
      append_metric_sample(lines, "paid_capacity_global_requested_disk_bytes_limit", global_infra_limits[:global_requested_disk_bytes_limit])

      append_metric_header(lines, "paid_capacity_host_concurrent_executions", "gauge", "Capacity-inflight runs attributed to a specific host.")
      append_metric_header(lines, "paid_capacity_host_concurrent_limit", "gauge", "Declared per-host concurrent execution limit. A value of 0 means unlimited.")
      append_metric_header(lines, "paid_capacity_host_requested_cpu_quota", "gauge", "Currently requested CPU quota attributed to a specific host.")
      append_metric_header(lines, "paid_capacity_host_requested_cpu_quota_limit", "gauge", "Configured per-host requested CPU quota ceiling.")
      append_metric_header(lines, "paid_capacity_host_requested_memory_bytes", "gauge", "Currently requested memory bytes attributed to a specific host.")
      append_metric_header(lines, "paid_capacity_host_requested_memory_bytes_limit", "gauge", "Configured per-host requested memory ceiling.")
      append_metric_header(lines, "paid_capacity_host_requested_disk_bytes", "gauge", "Currently requested disk bytes attributed to a specific host.")
      append_metric_header(lines, "paid_capacity_host_requested_disk_bytes_limit", "gauge", "Configured per-host requested disk ceiling.")
      registry.hosts.each do |host|
        host_active = AgentRun.active_count_for_host(host.identifier)
        host_requested = admission_snapshot.host_requested_resources(host.identifier)
        host_infra_limits = Capacity::InfrastructureLimits.current(host: host.identifier)
        append_metric_sample(lines, "paid_capacity_host_concurrent_executions", host_active, host: host.identifier)

        host_limit = host.max_concurrent_runs
        append_metric_sample(lines, "paid_capacity_host_concurrent_limit", host_limit || 0, host: host.identifier)
        append_metric_sample(lines, "paid_capacity_host_requested_cpu_quota", host_requested[:cpu_quota], host: host.identifier)
        append_metric_sample(lines, "paid_capacity_host_requested_cpu_quota_limit", host_infra_limits[:host_requested_cpu_quota_limit], host: host.identifier)
        append_metric_sample(lines, "paid_capacity_host_requested_memory_bytes", host_requested[:memory_bytes], host: host.identifier)
        append_metric_sample(lines, "paid_capacity_host_requested_memory_bytes_limit", host_infra_limits[:host_requested_memory_bytes_limit], host: host.identifier)
        append_metric_sample(lines, "paid_capacity_host_requested_disk_bytes", host_requested[:disk_bytes], host: host.identifier)
        append_metric_sample(lines, "paid_capacity_host_requested_disk_bytes_limit", host_infra_limits[:host_requested_disk_bytes_limit], host: host.identifier)
      end
    end

    def collect_agent_run_outcome_metrics(lines)
      outcome_counts = finished_run_counts_by_status

      append_metric_header(lines, RUN_OUTCOME_METRIC, "gauge", "Finished agent runs in the last #{FINISHED_RUN_WINDOW.in_hours.to_i}h by terminal status and normalized outcome. This is a sliding-window snapshot gauge, not a monotonic counter.")
      AgentRun::FINISHED_STATUSES.each do |status|
        append_metric_sample(
          lines,
          RUN_OUTCOME_METRIC,
          outcome_counts.fetch(status) { 0 },
          status: status,
          outcome: normalized_outcome_for(status)
        )
      end
    end

    def collect_agent_run_duration_metrics(lines)
      duration_counts = finished_run_durations_by_status

      append_metric_header(lines, RUN_DURATION_BUCKET_METRIC, "gauge", "Finished agent run duration bucket counts in the last #{FINISHED_RUN_WINDOW.in_hours.to_i}h by normalized outcome. Sliding-window snapshot; not a cumulative Prometheus histogram.")
      append_metric_header(lines, RUN_DURATION_SUM_METRIC, "gauge", "Total finished agent run duration in seconds in the last #{FINISHED_RUN_WINDOW.in_hours.to_i}h by normalized outcome. Sliding-window snapshot.")
      append_metric_header(lines, RUN_DURATION_COUNT_METRIC, "gauge", "Finished agent run counts with duration samples in the last #{FINISHED_RUN_WINDOW.in_hours.to_i}h by normalized outcome. Sliding-window snapshot.")
      RUN_OUTCOMES.each do |outcome|
        cumulative = 0
        grouped_counts = duration_counts.fetch(outcome) { Hash.new(0) }

        DURATION_BUCKETS.each do |bucket|
          cumulative += grouped_counts.fetch(bucket, 0)
          append_metric_sample(lines, RUN_DURATION_BUCKET_METRIC, cumulative, outcome: outcome, le: bucket)
        end

        total_count = grouped_counts.values.sum
        append_metric_sample(lines, RUN_DURATION_BUCKET_METRIC, total_count, outcome: outcome, le: "+Inf")
        append_metric_sample(lines, RUN_DURATION_SUM_METRIC, finished_run_duration_sums.fetch(outcome) { 0 }, outcome: outcome)
        append_metric_sample(lines, RUN_DURATION_COUNT_METRIC, total_count, outcome: outcome)
      end
    end

    def collect_agent_run_token_metrics(lines)
      append_metric_header(lines, RUN_TOKEN_METRIC, "gauge", "Finished agent-run tokens in the last #{FINISHED_RUN_WINDOW.in_hours.to_i}h by direction and normalized outcome. Sliding-window snapshot.")

      RUN_OUTCOMES.each do |outcome|
        append_metric_sample(lines, RUN_TOKEN_METRIC, finished_run_input_token_sums.fetch(outcome) { 0 }, direction: "input", outcome: outcome)
        append_metric_sample(lines, RUN_TOKEN_METRIC, finished_run_output_token_sums.fetch(outcome) { 0 }, direction: "output", outcome: outcome)
      end
    end

    def collect_agent_run_cost_metrics(lines)
      append_metric_header(lines, RUN_COST_METRIC, "gauge", "Finished agent-run cost in cents in the last #{FINISHED_RUN_WINDOW.in_hours.to_i}h by normalized outcome. Sliding-window snapshot.")

      RUN_OUTCOMES.each do |outcome|
        append_metric_sample(lines, RUN_COST_METRIC, finished_run_cost_sums.fetch(outcome) { 0 }, outcome: outcome)
      end
    end

    def finished_run_scope
      AgentRun.where(status: AgentRun::FINISHED_STATUSES)
              .where(completed_at: FINISHED_RUN_WINDOW.ago..)
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

    # Maps each terminal status to a normalized outcome bucket for Prometheus metrics.
    #
    # "no_output" is a success-like terminal state: the provider ran fine but produced
    # no changes. The app consistently treats it as a successful provider outcome
    # (see SUCCESSFUL_RUN_STATUSES in StrategyEvolution::PrepareInputs, circuit breaker,
    # and STALE_RUNNING_HEALTHY_STATUSES).
    #
    # FAILURE_STATUSES (%w[failed timeout token_budget_exceeded auth_expired rate_limited])
    # are real provider failures that should drive failure-rate alerting.
    #
    # "cancelled" and "retried" are NOT real provider outcomes: "cancelled" means a
    # human or system cancelled the run before provider execution; "retried" means the
    # run was absorbed into a framework-level retry. The app explicitly skips these in
    # the circuit breaker (see AgentRun#record_dispatch_circuit_breaker_outcome).
    # Folding them into "failure" would inflate PaidAgentRunFailureRateHigh.
    def normalized_outcome_for(status)
      if %w[completed no_output].include?(status)
        "success"
      elsif AgentRun::FAILURE_STATUSES.include?(status)
        "failure"
      else
        "non_provider"
      end
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
