# frozen_string_literal: true

module QualityPause
  # Evaluates recent quality metrics for a project against the configured
  # quality threshold. When the rolling average falls below the threshold,
  # automatically pauses automatic agent runs for the project.
  #
  # Called after each agent run completes and quality metrics are collected.
  #
  # @example
  #   QualityPause::Check.call(agent_run: agent_run)
  class Check
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
      @project = agent_run.project
    end

    def call
      return if project.quality_paused?

      breached = breached_threshold
      return unless breached

      project.quality_pause!(
        score: breached.fetch(:average),
        threshold: breached.fetch(:threshold).min_value,
        agent_run: agent_run,
        metadata: {
          metric_type: breached.fetch(:threshold).metric_type,
          goal_type: agent_run.goal,
          window_size: QualityThreshold::DEFAULT_WINDOW_SIZE,
          sample_size: breached.fetch(:sample_size),
          recent_scores: breached.fetch(:scores)
        }
      )

      Rails.logger.warn(
        message: "quality_pause.project_paused",
        project_id: project.id,
        metric_type: breached.fetch(:threshold).metric_type,
        goal_type: agent_run.goal,
        rolling_average: breached.fetch(:average),
        threshold: breached.fetch(:threshold).min_value,
        agent_run_id: agent_run.id
      )
    end

    private

    attr_reader :agent_run, :project

    def breached_threshold
      thresholds.each do |threshold|
        scores = recent_scores_for(threshold.metric_type)
        next if scores.size < QualityThreshold::DEFAULT_MIN_SAMPLE_SIZE

        average = (scores.sum / scores.size).round(4)
        next unless threshold.breached?(average)

        return { threshold: threshold, scores: scores, average: average, sample_size: scores.size }
      end
      nil
    end

    def thresholds
      @thresholds ||= QualityThreshold.effective_for(project: project, goal_type: agent_run.goal)
    end

    def recent_scores_for(metric_type)
      recent_metrics_for(metric_type).filter_map do |metric|
        score_for(metric, metric_type)
      end
    end

    def recent_metrics_for(metric_type)
      @recent_metrics_by_type ||= {}
      @recent_metrics_by_type[metric_type] ||= metrics_for(metric_type)
        .limit(QualityThreshold::DEFAULT_WINDOW_SIZE)
        .to_a
    end

    def metrics_for(metric_type)
      scope = QualityMetric.by_project(project.id)
        .where(agent_runs: { goal: agent_run.goal })
        .where(AgentRun.quality_scoreable_sql)
        .order(created_at: :desc)

      if metric_type == "composite_score"
        scope.where.not(composite_score: nil)
      else
        scope.where("jsonb_exists(quality_metrics.scores, ?)", metric_type)
      end
    end

    def score_for(metric, metric_type)
      if metric_type == "composite_score"
        metric.composite_score&.to_f
      else
        metric.scores&.dig(metric_type)&.to_f
      end
    end
  end
end
