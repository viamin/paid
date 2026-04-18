# frozen_string_literal: true

module QualityAlerts
  # Evaluates recent quality metrics for a project against configured thresholds
  # and returns a structured assessment of which gates were breached.
  #
  # @example
  #   result = QualityAlerts::Evaluate.call(project: project)
  #   result[:breached] # => true
  #   result[:breaches] # => [{ metric: "composite_score", current: 0.35, threshold: 0.5, ... }]
  class Evaluate
    LOOKBACK_WINDOW_HOURS_DEFAULT = 24
    MIN_RECENT_RUNS_DEFAULT = 3
    COMPOSITE_SCORE_THRESHOLD_DEFAULT = 0.5

    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
      @settings = project.effective_quality_gate_settings
    end

    def call
      return inactive_result unless settings["enabled"]

      recent_metrics = fetch_recent_metrics
      return insufficient_data_result(recent_metrics.size) if recent_metrics.size < min_recent_runs

      breaches = detect_breaches(recent_metrics)
      recent_runs = summarize_recent_runs(recent_metrics)

      {
        breached: breaches.any?,
        breaches: breaches,
        recent_runs: recent_runs,
        remediation_actions: breaches.any? ? remediation_actions(breaches) : [],
        evaluated_at: Time.current.iso8601,
        window_hours: lookback_window_hours,
        sample_size: recent_metrics.size
      }
    end

    private

    attr_reader :project, :settings

    def fetch_recent_metrics
      cutoff = lookback_window_hours.hours.ago
      QualityMetric
        .by_project(project.id)
        .automated
        .with_composite_score
        .where(created_at: cutoff..)
        .order(created_at: :desc)
        .limit(50)
        .to_a
    end

    def detect_breaches(metrics)
      breaches = []

      avg_composite = metrics.sum(&:composite_score) / metrics.size
      if avg_composite < composite_score_threshold
        breaches << {
          metric: "composite_score",
          current: avg_composite.round(4),
          threshold: composite_score_threshold,
          description: "Average composite quality score (#{format('%.1f%%', avg_composite * 100)}) " \
                       "is below threshold (#{format('%.1f%%', composite_score_threshold * 100)})"
        }
      end

      metric_thresholds.each do |metric_key, threshold|
        values = metrics.filter_map { |m| m.scores&.dig(metric_key)&.to_f }
        next if values.empty?

        avg = values.sum / values.size
        next unless avg < threshold

        breaches << {
          metric: metric_key,
          current: avg.round(4),
          threshold: threshold,
          description: "Average #{metric_key.titleize} (#{format('%.1f%%', avg * 100)}) " \
                       "is below threshold (#{format('%.1f%%', threshold * 100)})"
        }
      end

      breaches
    end

    def summarize_recent_runs(metrics)
      metrics.first(5).map do |m|
        {
          agent_run_id: m.agent_run_id,
          composite_score: m.composite_score.to_f.round(4),
          scores: m.scores,
          created_at: m.created_at.iso8601
        }
      end
    end

    def remediation_actions(breaches)
      actions = []
      metric_names = breaches.map { |b| b[:metric] }

      if metric_names.include?("composite_score")
        actions << "Review recent agent runs for overall quality regression"
      end

      if metric_names.include?("pr_created") || metric_names.include?("pr_merged")
        actions << "Check recent PRs for issues preventing creation or merge"
      end

      if metric_names.include?("iterations") || metric_names.include?("agent_rerun_count")
        actions << "Investigate why agents need multiple iterations — prompts may need tuning"
      end

      if metric_names.include?("lint_clean") || metric_names.include?("tests_pass")
        actions << "Review code quality tooling — lint or test failures may indicate prompt drift"
      end

      if metric_names.include?("review_comment_count")
        actions << "High review comment counts suggest agent output needs improvement"
      end

      actions << "Check for recent prompt version changes that may have caused regression"
      actions << "Review the quality dashboard for trend details"
      actions.uniq
    end

    def lookback_window_hours
      settings.fetch("lookback_window_hours", LOOKBACK_WINDOW_HOURS_DEFAULT)
    end

    def min_recent_runs
      settings.fetch("min_recent_runs", MIN_RECENT_RUNS_DEFAULT)
    end

    def composite_score_threshold
      settings.fetch("composite_score_threshold", COMPOSITE_SCORE_THRESHOLD_DEFAULT)
    end

    def metric_thresholds
      settings.fetch("metric_thresholds", {})
    end

    def inactive_result
      { breached: false, breaches: [], reason: "quality_gates_disabled" }
    end

    def insufficient_data_result(count)
      {
        breached: false,
        breaches: [],
        reason: "insufficient_data",
        sample_size: count,
        min_required: min_recent_runs
      }
    end
  end
end
