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
    MINIMUM_SAMPLE_SIZE = 3
    DEFAULT_WINDOW_SIZE = 5

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
      @project = agent_run.project
    end

    def call
      return unless threshold
      return if project.quality_paused?

      trend = QualityMetrics::TrendAnalysis.call(
        project_id: project.id,
        window_size: DEFAULT_WINDOW_SIZE
      )

      return unless trend[:sample_size] >= MINIMUM_SAMPLE_SIZE
      return unless trend[:rolling_average]
      return if trend[:rolling_average] >= threshold

      project.quality_pause!(
        score: trend[:rolling_average],
        threshold: threshold,
        agent_run: agent_run,
        metadata: {
          window_size: DEFAULT_WINDOW_SIZE,
          sample_size: trend[:sample_size],
          recent_scores: trend[:recent_scores]
        }
      )

      Rails.logger.warn(
        message: "quality_pause.project_paused",
        project_id: project.id,
        rolling_average: trend[:rolling_average],
        threshold: threshold,
        agent_run_id: agent_run.id
      )
    end

    private

    attr_reader :agent_run, :project

    def threshold
      @threshold ||= project.quality_pause_threshold
    end
  end
end
