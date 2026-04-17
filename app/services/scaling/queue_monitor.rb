# frozen_string_literal: true

module Scaling
  class QueueMonitor
    GOOD_JOB_QUEUES = %w[default maintenance metrics knowledge low_priority].freeze

    DEFAULT_THRESHOLDS = {
      good_job: {
        warning: 50,
        critical: 200
      },
      temporal: {
        warning: 100,
        critical: 500
      },
      agent_run_queue: {
        warning: 20,
        critical: 50
      }
    }.freeze

    Result = Struct.new(:queue_depths, :alerts, :healthy?, keyword_init: true)
    QueueDepth = Struct.new(:name, :type, :depth, :threshold_warning, :threshold_critical, :status, keyword_init: true)
    Alert = Struct.new(:queue_name, :queue_type, :depth, :threshold, :severity, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(account: nil, thresholds: {}, only: nil)
      @account = account
      @thresholds = DEFAULT_THRESHOLDS.deep_merge(thresholds)
      @only = only
    end

    def call
      depths = []
      alerts = []

      unless only == :agent_run_queue
        depths.concat(measure_good_job_queues)
        depths.concat(measure_temporal_queues)
      end
      depths.concat(measure_agent_run_queue) if only.nil? || only == :agent_run_queue

      depths.each do |depth|
        alert = evaluate_threshold(depth)
        alerts << alert if alert
      end

      log_results(depths, alerts)

      Result.new(
        queue_depths: depths,
        alerts: alerts,
        healthy?: alerts.none? { |a| a.severity == :critical }
      )
    end

    private

    attr_reader :account, :thresholds, :only

    def measure_good_job_queues
      counts = GoodJob::Job.where(finished_at: nil)
        .group(:queue_name)
        .count

      GOOD_JOB_QUEUES.map do |queue_name|
        depth = counts.fetch(queue_name, 0)
        QueueDepth.new(
          name: queue_name,
          type: :good_job,
          depth: depth,
          threshold_warning: thresholds.dig(:good_job, :warning),
          threshold_critical: thresholds.dig(:good_job, :critical),
          status: status_for(depth, :good_job)
        )
      end
    end

    def measure_temporal_queues
      task_queue = Paid.task_queue
      depth = fetch_temporal_queue_depth(task_queue)

      [
        QueueDepth.new(
          name: task_queue,
          type: :temporal,
          depth: depth,
          threshold_warning: thresholds.dig(:temporal, :warning),
          threshold_critical: thresholds.dig(:temporal, :critical),
          status: status_for(depth, :temporal)
        )
      ]
    rescue => e
      Rails.logger.warn(
        message: "scaling.queue_monitor.temporal_unavailable",
        error: e.message
      )
      []
    end

    def measure_agent_run_queue
      depth = if account
        AgentRun.joins(:project)
          .where(projects: { account_id: account.id })
          .where(status: "queued").count
      else
        AgentRun.where(status: "queued").count
      end

      [
        QueueDepth.new(
          name: "agent_runs",
          type: :agent_run_queue,
          depth: depth,
          threshold_warning: thresholds.dig(:agent_run_queue, :warning),
          threshold_critical: thresholds.dig(:agent_run_queue, :critical),
          status: status_for(depth, :agent_run_queue)
        )
      ]
    end

    def fetch_temporal_queue_depth(task_queue)
      count_running_workflows(Paid.temporal_client, task_queue)
    end

    def count_running_workflows(client, task_queue)
      sanitized_queue = task_queue.gsub("'", "\\\\'")
      count = 0
      client.list_workflows("TaskQueue = '#{sanitized_queue}' AND ExecutionStatus = 'Running'").each do |_wf|
        count += 1
      end
      count
    rescue => e
      Rails.logger.warn(
        message: "scaling.queue_monitor.temporal_count_failed",
        task_queue: task_queue,
        error: e.message
      )
      0
    end

    def status_for(depth, queue_type)
      critical = thresholds.dig(queue_type, :critical)
      warning = thresholds.dig(queue_type, :warning)

      if critical && depth >= critical
        :critical
      elsif warning && depth >= warning
        :warning
      else
        :ok
      end
    end

    def evaluate_threshold(depth)
      return unless depth.status != :ok

      Alert.new(
        queue_name: depth.name,
        queue_type: depth.type,
        depth: depth.depth,
        threshold: depth.status == :critical ? depth.threshold_critical : depth.threshold_warning,
        severity: depth.status
      )
    end

    def log_results(depths, alerts)
      Rails.logger.info(
        message: "scaling.queue_monitor.completed",
        queue_count: depths.size,
        alert_count: alerts.size,
        depths: depths.map { |d| { name: d.name, type: d.type, depth: d.depth, status: d.status } }
      )

      alerts.each do |alert|
        Rails.logger.warn(
          message: "scaling.queue_monitor.threshold_exceeded",
          queue_name: alert.queue_name,
          queue_type: alert.queue_type,
          depth: alert.depth,
          threshold: alert.threshold,
          severity: alert.severity
        )
      end
    end
  end
end
