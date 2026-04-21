# frozen_string_literal: true

module Metrics
  # Collects application metrics and renders them in Prometheus text exposition format.
  # Used by the /api/metrics endpoint to feed external auto-scaling systems.
  class PrometheusCollector
    def self.call
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

      lines << "# HELP paid_agent_runs_total Number of agent runs by status."
      lines << "# TYPE paid_agent_runs_total gauge"
      AgentRun::STATUSES.each do |status|
        lines << "paid_agent_runs_total{status=\"#{status}\"} #{counts.fetch(status, 0)}"
      end

      active = counts.values_at(*AgentRun::ACTIVE_STATUSES).compact.sum
      lines << "# HELP paid_agent_runs_active Currently active agent runs."
      lines << "# TYPE paid_agent_runs_active gauge"
      lines << "paid_agent_runs_active #{active}"

      queued = counts.fetch("queued", 0)
      lines << "# HELP paid_agent_runs_queued Agent runs waiting in queue."
      lines << "# TYPE paid_agent_runs_queued gauge"
      lines << "paid_agent_runs_queued #{queued}"
    end

    def collect_good_job_metrics(lines)
      queue_counts = GoodJob::Job.where(finished_at: nil)
                                 .group(:queue_name)
                                 .count

      lines << "# HELP paid_goodjob_queue_depth Number of unfinished jobs per queue."
      lines << "# TYPE paid_goodjob_queue_depth gauge"
      queue_counts.each do |queue, count|
        lines << "paid_goodjob_queue_depth{queue=\"#{queue}\"} #{count}"
      end

      total_unfinished = queue_counts.values.sum
      lines << "# HELP paid_goodjob_jobs_unfinished Total unfinished GoodJob jobs."
      lines << "# TYPE paid_goodjob_jobs_unfinished gauge"
      lines << "paid_goodjob_jobs_unfinished #{total_unfinished}"

      running = GoodJob::Job.where.not(performed_at: nil).where(finished_at: nil).count
      errored = GoodJob::Job.where.not(error: nil).where(finished_at: nil).count

      lines << "# HELP paid_goodjob_jobs_running GoodJob jobs currently executing."
      lines << "# TYPE paid_goodjob_jobs_running gauge"
      lines << "paid_goodjob_jobs_running #{running}"

      lines << "# HELP paid_goodjob_jobs_errored GoodJob jobs in error state."
      lines << "# TYPE paid_goodjob_jobs_errored gauge"
      lines << "paid_goodjob_jobs_errored #{errored}"
    end

    def collect_container_metrics(lines)
      active_runs = AgentRun.where(status: AgentRun::ACTIVE_STATUSES)
                            .where.not(container_id: [ nil, "" ])

      lines << "# HELP paid_containers_active Containers running agent work."
      lines << "# TYPE paid_containers_active gauge"
      lines << "paid_containers_active #{active_runs.distinct.count(:container_id)}"

      latest_metrics = ContainerMetric
        .where(agent_run_id: active_runs.select(:id))
        .where(recorded_at: 5.minutes.ago..)
        .select("DISTINCT ON (container_id) container_id, cpu_percent, memory_bytes, memory_limit_bytes, memory_percent")
        .order(:container_id, recorded_at: :desc)

      if latest_metrics.any?
        avg_cpu = latest_metrics.sum(&:cpu_percent) / latest_metrics.size
        avg_mem = latest_metrics.sum(&:memory_percent) / latest_metrics.size
        total_memory_bytes = latest_metrics.sum(&:memory_bytes)

        lines << "# HELP paid_containers_avg_cpu_percent Average CPU usage across active containers."
        lines << "# TYPE paid_containers_avg_cpu_percent gauge"
        lines << "paid_containers_avg_cpu_percent #{avg_cpu.round(2)}"

        lines << "# HELP paid_containers_avg_memory_percent Average memory usage across active containers."
        lines << "# TYPE paid_containers_avg_memory_percent gauge"
        lines << "paid_containers_avg_memory_percent #{avg_mem.round(2)}"

        lines << "# HELP paid_containers_total_memory_bytes Total memory used by active containers."
        lines << "# TYPE paid_containers_total_memory_bytes gauge"
        lines << "paid_containers_total_memory_bytes #{total_memory_bytes}"
      end
    end

    def collect_container_pool_metrics(lines)
      status_counts = ContainerPoolEntry.group(:status).count

      lines << "# HELP paid_container_pool_entries_total Warm container pool entries by status."
      lines << "# TYPE paid_container_pool_entries_total gauge"
      ContainerPoolEntry::STATUSES.each do |status|
        lines << "paid_container_pool_entries_total{status=\"#{status}\"} #{status_counts.fetch(status, 0)}"
      end

      target = Containers::PoolManager.target_size * Project.active.count
      lines << "# HELP paid_container_pool_target Target warm container pool size."
      lines << "# TYPE paid_container_pool_target gauge"
      lines << "paid_container_pool_target #{target}"
    end

    def collect_service_container_metrics(lines)
      status_counts = ServiceContainer.group(:status).count

      lines << "# HELP paid_service_containers_total Service containers by status."
      lines << "# TYPE paid_service_containers_total gauge"
      ServiceContainer::STATUSES.each do |status|
        lines << "paid_service_containers_total{status=\"#{status}\"} #{status_counts.fetch(status, 0)}"
      end

      running_ids = ServiceContainer.where(status: "running").select(:id)
      latest_svc_metrics = ServiceContainerMetric
        .where(service_container_id: running_ids)
        .where(recorded_at: 5.minutes.ago..)
        .select("DISTINCT ON (service_container_id) service_container_id, cpu_percent, memory_bytes, memory_percent")
        .order(:service_container_id, recorded_at: :desc)

      if latest_svc_metrics.any?
        lines << "# HELP paid_service_containers_avg_cpu_percent Average CPU across running service containers."
        lines << "# TYPE paid_service_containers_avg_cpu_percent gauge"
        avg_cpu = latest_svc_metrics.sum(&:cpu_percent) / latest_svc_metrics.size
        lines << "paid_service_containers_avg_cpu_percent #{avg_cpu.round(2)}"

        lines << "# HELP paid_service_containers_avg_memory_percent Average memory across running service containers."
        lines << "# TYPE paid_service_containers_avg_memory_percent gauge"
        avg_mem = latest_svc_metrics.sum(&:memory_percent) / latest_svc_metrics.size
        lines << "paid_service_containers_avg_memory_percent #{avg_mem.round(2)}"
      end
    end

    def collect_temporal_config_metrics(lines)
      slots = temporal_env("TEMPORAL_WORKFLOW_SLOTS", 20)

      lines << "# HELP paid_temporal_workflow_slots_total Configured Temporal workflow slots."
      lines << "# TYPE paid_temporal_workflow_slots_total gauge"
      lines << "paid_temporal_workflow_slots_total #{slots}"

      lines << "# HELP paid_temporal_activity_slots_total Configured Temporal activity slots."
      lines << "# TYPE paid_temporal_activity_slots_total gauge"
      lines << "paid_temporal_activity_slots_total #{temporal_env("TEMPORAL_ACTIVITY_SLOTS", 4)}"

      running_workflows = AgentRun.running.where.not(temporal_workflow_id: [ nil, "" ]).count
      lines << "# HELP paid_temporal_workflows_running Temporal workflows currently running."
      lines << "# TYPE paid_temporal_workflows_running gauge"
      lines << "paid_temporal_workflows_running #{running_workflows}"

      utilization = if slots.positive?
        (running_workflows.to_f / slots * 100).round(2)
      else
        0.0
      end
      lines << "# HELP paid_temporal_workflow_utilization_percent Workflow slot utilization percentage."
      lines << "# TYPE paid_temporal_workflow_utilization_percent gauge"
      lines << "paid_temporal_workflow_utilization_percent #{utilization}"
    end

    def temporal_env(key, default)
      Integer(ENV.fetch(key, default))
    rescue ArgumentError
      Integer(default)
    end
  end
end
