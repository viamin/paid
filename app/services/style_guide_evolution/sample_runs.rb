# frozen_string_literal: true

module StyleGuideEvolution
  class SampleRuns
    Result = Struct.new(:samples, :style_guide_stats, :evolution_candidates, keyword_init: true)

    DEFAULT_SAMPLE_SIZE = 50
    DEFAULT_DAYS = 14
    QUALITY_THRESHOLD = 0.7
    MIN_RUNS_FOR_EVALUATION = 5

    attr_reader :style_guide_id, :project_id, :sample_size, :days, :threshold

    def initialize(style_guide_id:, project_id: nil, sample_size: DEFAULT_SAMPLE_SIZE, days: DEFAULT_DAYS, threshold: QUALITY_THRESHOLD)
      @style_guide_id = style_guide_id
      @project_id = project_id
      @sample_size = sample_size
      @days = days
      @threshold = threshold.to_f
    end

    def self.call(...)
      new(...).sample
    end

    def sample
      samples = fetch_samples
      stats = calculate_stats(samples)
      candidates = identify_candidates(stats)

      Result.new(samples:, style_guide_stats: stats, evolution_candidates: candidates)
    end

    private

    def fetch_samples
      exposures = StyleGuideRunExposure
        .includes(:style_guide_version, :agent_run)
        .joins(agent_run: :quality_metrics)
        .where(style_guide_id: style_guide_id)
        .where(created_at: days.days.ago..)
        .merge(QualityMetric.automated.with_composite_score)
        .joins(:agent_run).where(AgentRun.quality_scoreable_sql)
        .order(created_at: :desc)
      exposures = exposures.where(agent_runs: { project_id: project_id }) if project_id

      exposures.limit(sample_size).map do |exposure|
        metric = exposure.agent_run.quality_metrics.find { |record| record.metric_type == "automated" }
        {
          exposure: exposure,
          agent_run: exposure.agent_run,
          style_guide_version: exposure.style_guide_version,
          composite_score: metric&.composite_score&.to_f,
          scores: metric&.scores || {}
        }
      end
    end

    def calculate_stats(samples)
      grouped = samples.group_by { |sample| sample[:style_guide_version].id }
      grouped.transform_values do |version_samples|
        scores = version_samples.filter_map { |sample| sample[:composite_score] }
        {
          style_guide_version: version_samples.first[:style_guide_version],
          run_count: version_samples.size,
          avg_score: scores.any? ? (scores.sum / scores.size).to_f : nil
        }
      end
    end

    def identify_candidates(stats)
      stats.filter_map do |_id, version_stats|
        next if version_stats[:run_count] < MIN_RUNS_FOR_EVALUATION
        next if version_stats[:avg_score].nil? || version_stats[:avg_score] >= threshold

        {
          style_guide_version: version_stats[:style_guide_version],
          avg_score: version_stats[:avg_score],
          run_count: version_stats[:run_count],
          reasons: [ "avg quality score #{version_stats[:avg_score].round(4)} below threshold #{threshold}" ]
        }
      end
    end
  end
end
