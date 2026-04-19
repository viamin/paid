# frozen_string_literal: true

module QualityRecovery
  # Analyzes recent agent run failures for a project to identify common patterns
  # that are causing quality degradation. Returns a structured diagnosis with
  # failure patterns, affected prompt versions, and severity assessment.
  #
  # @example
  #   diagnosis = QualityRecovery::Diagnose.call(project: project, window: 20)
  #   diagnosis[:patterns]       # => [{ type: "high_failure_rate", ... }]
  #   diagnosis[:severity]       # => "critical"
  class Diagnose
    MINIMUM_SAMPLE_SIZE = 5
    FAILURE_RATE_WARNING = 0.3
    FAILURE_RATE_CRITICAL = 0.5
    QUALITY_DROP_THRESHOLD = 0.15

    def self.call(...)
      new(...).call
    end

    def initialize(project:, window: 20)
      @project = project
      @window = window
    end

    def call
      recent_runs = fetch_recent_runs
      return empty_diagnosis if recent_runs.size < MINIMUM_SAMPLE_SIZE

      patterns = []
      patterns.concat(detect_failure_rate(recent_runs))
      patterns.concat(detect_quality_drop(recent_runs))
      patterns.concat(detect_prompt_regression(recent_runs))
      patterns.concat(detect_model_issues(recent_runs))
      patterns.concat(detect_anomaly_clusters)

      {
        project_id: project.id,
        sample_size: recent_runs.size,
        patterns: patterns,
        severity: assess_severity(patterns),
        analyzed_at: Time.current.iso8601
      }
    end

    private

    attr_reader :project, :window

    def fetch_recent_runs
      project.agent_runs
        .where(status: AgentRun::FINISHED_STATUSES)
        .order(completed_at: :desc)
        .limit(window)
        .includes(:quality_metrics, :prompt_version)
    end

    def empty_diagnosis
      {
        project_id: project.id,
        sample_size: 0,
        patterns: [],
        severity: "none",
        analyzed_at: Time.current.iso8601
      }
    end

    def detect_failure_rate(runs)
      failed = runs.count { |r| AgentRun::FAILURE_STATUSES.include?(r.status) }
      rate = failed.to_f / runs.size

      return [] if rate < FAILURE_RATE_WARNING

      [ {
        type: "high_failure_rate",
        severity: rate >= FAILURE_RATE_CRITICAL ? "critical" : "warning",
        details: {
          failure_count: failed,
          total_count: runs.size,
          failure_rate: rate.round(4),
          statuses: runs.select { |r| AgentRun::FAILURE_STATUSES.include?(r.status) }
                        .group_by(&:status)
                        .transform_values(&:count)
        }
      } ]
    end

    def detect_quality_drop(runs)
      metrics = runs.filter_map { |r| r.quality_metrics.find { |m| m.metric_type == "automated" } }
      return [] if metrics.size < MINIMUM_SAMPLE_SIZE

      scores = metrics.map(&:composite_score).compact
      return [] if scores.size < MINIMUM_SAMPLE_SIZE

      midpoint = scores.size / 2
      recent_avg = scores[0...midpoint].sum / midpoint.to_f
      older_avg = scores[midpoint..].sum / (scores.size - midpoint).to_f

      drop = older_avg - recent_avg
      return [] if drop < QUALITY_DROP_THRESHOLD

      [ {
        type: "quality_score_decline",
        severity: drop >= QUALITY_DROP_THRESHOLD * 2 ? "critical" : "warning",
        details: {
          recent_average: recent_avg.round(4),
          older_average: older_avg.round(4),
          drop: drop.round(4)
        }
      } ]
    end

    def detect_prompt_regression(runs)
      by_version = runs.group_by(&:prompt_version_id).reject { |k, _| k.nil? }
      return [] if by_version.empty?

      regressions = []
      by_version.each do |version_id, version_runs|
        next if version_runs.size < 3

        failed = version_runs.count { |r| AgentRun::FAILURE_STATUSES.include?(r.status) }
        rate = failed.to_f / version_runs.size

        next unless rate >= FAILURE_RATE_WARNING

        pv = version_runs.first.prompt_version
        regressions << {
          type: "prompt_version_regression",
          severity: rate >= FAILURE_RATE_CRITICAL ? "critical" : "warning",
          details: {
            prompt_version_id: version_id,
            prompt_name: pv&.prompt&.name,
            version_number: pv&.version,
            failure_rate: rate.round(4),
            run_count: version_runs.size
          }
        }
      end

      regressions
    end

    def detect_model_issues(runs)
      by_agent = runs.group_by(&:agent_type)
      issues = []

      by_agent.each do |agent_type, agent_runs|
        next if agent_runs.size < 3

        failed = agent_runs.count { |r| AgentRun::FAILURE_STATUSES.include?(r.status) }
        rate = failed.to_f / agent_runs.size

        next unless rate >= FAILURE_RATE_WARNING

        issues << {
          type: "agent_type_failures",
          severity: rate >= FAILURE_RATE_CRITICAL ? "critical" : "warning",
          details: {
            agent_type: agent_type,
            failure_rate: rate.round(4),
            run_count: agent_runs.size,
            error_messages: agent_runs.filter_map(&:error_message).first(3)
          }
        }
      end

      issues
    end

    def detect_anomaly_clusters
      recent_anomalies = project.agent_run_anomalies
        .where(created_at: 24.hours.ago..)
        .order(created_at: :desc)

      return [] if recent_anomalies.empty?

      by_metric = recent_anomalies.group_by(&:metric_name)
      clusters = []

      by_metric.each do |metric_name, anomalies|
        next if anomalies.size < 2

        critical_count = anomalies.count { |a| a.severity == "critical" }
        clusters << {
          type: "anomaly_cluster",
          severity: critical_count > 0 ? "critical" : "warning",
          details: {
            metric_name: metric_name,
            anomaly_count: anomalies.size,
            critical_count: critical_count,
            avg_deviation: (anomalies.sum(&:deviation_factor) / anomalies.size).round(2)
          }
        }
      end

      clusters
    end

    def assess_severity(patterns)
      return "none" if patterns.empty?
      return "critical" if patterns.any? { |p| p[:severity] == "critical" }

      "warning"
    end
  end
end
