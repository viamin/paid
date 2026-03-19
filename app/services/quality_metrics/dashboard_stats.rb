# frozen_string_literal: true

module QualityMetrics
  # Computes quality metrics dashboard data for a project.
  # Provides composite scores, trends, breakdowns, prompt comparisons,
  # and human feedback summaries.
  #
  # @example
  #   stats = QualityMetrics::DashboardStats.call(project: project)
  class DashboardStats
    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def self.overview(...)
      new(...).overview
    end

    def call
      {
        overview: overview,
        trends: trends,
        breakdown: score_breakdown,
        prompt_comparison: prompt_comparison,
        human_feedback: human_feedback
      }
    end

    def overview
      row = metrics
        .select(
          "COUNT(*) AS total_metrics",
          "AVG(composite_score) AS avg_score",
          "MIN(composite_score) AS min_score",
          "MAX(composite_score) AS max_score",
          "COUNT(*) FILTER (WHERE metric_type = 'automated') AS automated_count",
          "COUNT(*) FILTER (WHERE metric_type = 'human') AS human_count"
        )
        .take

      {
        total_metrics: row.total_metrics.to_i,
        average_score: row.avg_score&.to_f&.round(4),
        min_score: row.min_score&.to_f,
        max_score: row.max_score&.to_f,
        automated_count: row.automated_count.to_i,
        human_count: row.human_count.to_i
      }
    end

    private

    def metrics
      @metrics ||= QualityMetric.by_project(project.id).with_composite_score
    end

    def trends
      recent = metrics
        .select("quality_metrics.composite_score, quality_metrics.created_at, quality_metrics.metric_type")
        .order("quality_metrics.created_at DESC")
        .limit(30)

      recent.reverse.map do |m|
        {
          score: m.composite_score.to_f,
          date: m.created_at.to_date.iso8601,
          metric_type: m.metric_type
        }
      end
    end

    def score_breakdown
      valid_keys = QualityMetric::SCORE_WEIGHTS.keys
      rows = QualityMetric.by_project(project.id).automated.with_composite_score
        .where("scores <> '{}'::jsonb")
        .joins("CROSS JOIN LATERAL jsonb_each_text(scores) AS kv(key, val)")
        .where("kv.key IN (?)", valid_keys)
        .group("kv.key")
        .pluck(Arel.sql("kv.key, AVG(kv.val::float)"))

      rows.to_h { |key, avg| [ key, avg.to_f.round(4) ] }
    end

    def prompt_comparison
      version_metrics = metrics.where.not(prompt_version_id: nil)
        .group(:prompt_version_id)
        .select(
          "prompt_version_id",
          "AVG(composite_score) AS avg_score",
          "COUNT(*) AS sample_size"
        )
        .to_a

      return [] if version_metrics.empty?

      version_ids = version_metrics.map(&:prompt_version_id)
      versions_by_id = PromptVersion.includes(:prompt).where(id: version_ids).index_by(&:id)

      version_metrics.filter_map do |row|
        version = versions_by_id[row.prompt_version_id]
        next unless version

        {
          prompt_version_id: row.prompt_version_id,
          prompt_name: version.prompt.name,
          version_number: version.version,
          avg_score: row.avg_score.to_f.round(4),
          sample_size: row.sample_size.to_i
        }
      end.sort_by { |r| -r[:avg_score] }
    end

    def human_feedback
      human = QualityMetric.by_project(project.id).human

      row = human.select(
        "COUNT(*) AS total",
        "COUNT(*) FILTER (WHERE scores ? 'pr_merged') AS with_merge_status",
        "COUNT(*) FILTER (WHERE (scores->>'pr_merged')::float = 1.0) AS merged_count"
      ).take

      total = row.total.to_i
      return { total: 0, merge_rate: nil, sources: {} } if total.zero?

      with_merge_status = row.with_merge_status.to_i
      merged_count = row.merged_count.to_i
      sources = human.where.not(feedback_source: nil).group(:feedback_source).count

      {
        total: total,
        merge_rate: with_merge_status.zero? ? nil : (merged_count.to_f / with_merge_status * 100).round(1),
        sources: sources
      }
    end
  end
end
