# frozen_string_literal: true

module QualityPause
  # Evaluates recent quality metrics for a project against the configured
  # quality threshold. Breaches start or advance the auto-improvement cycle;
  # automatic runs are paused only after recovery attempts fail.
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
      return if in_grace_period?(breached)

      QualityRecovery::AutoImprove.call(agent_run: agent_run, breach: breached)

      Rails.logger.info(
        message: "quality_recovery.breach_detected",
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

    def in_grace_period?(breached)
      resume_at = last_resume_at
      return false unless resume_at

      metric_type = breached.fetch(:threshold).metric_type
      samples_since_resume = metrics_for(metric_type)
        .where("agent_runs.completed_at > ?", resume_at)
        .count

      return false unless samples_since_resume < QualityThreshold::DEFAULT_WINDOW_SIZE

      Rails.logger.info(
        message: "quality_pause.grace_period_active",
        project_id: project.id,
        goal: agent_run.goal,
        metric_type: metric_type,
        samples_since_resume: samples_since_resume,
        grace_window: QualityThreshold::DEFAULT_WINDOW_SIZE
      )

      true
    end

    def last_resume_at
      project.quality_pause_events.resumes
        .order(created_at: :desc).pick(:created_at)
    end

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
