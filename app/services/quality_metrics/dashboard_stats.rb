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

    def call
      {
        overview: overview,
        trends: trends,
        breakdown: score_breakdown,
        prompt_comparison: prompt_comparison,
        human_feedback: human_feedback
      }
    end

    private

    def metrics
      @metrics ||= QualityMetric.by_project(project.id).with_composite_score
    end

    def overview
      scores = metrics.pluck(:composite_score)
      {
        total_metrics: scores.size,
        average_score: scores.any? ? (scores.sum / scores.size).round(4) : nil,
        min_score: scores.min,
        max_score: scores.max,
        automated_count: metrics.automated.count,
        human_count: metrics.human.count
      }
    end

    def trends
      recent = metrics
        .joins(:agent_run)
        .select("quality_metrics.composite_score, quality_metrics.created_at, quality_metrics.metric_type")
        .order("quality_metrics.created_at ASC")
        .last(30)

      recent.map do |m|
        {
          score: m.composite_score.to_f,
          date: m.created_at.to_date.iso8601,
          metric_type: m.metric_type
        }
      end
    end

    def score_breakdown
      automated = QualityMetric.by_project(project.id).automated.with_composite_score
      return {} if automated.none?

      weight_keys = QualityMetric::SCORE_WEIGHTS.keys
      totals = Hash.new(0.0)
      count = 0

      automated.find_each do |metric|
        next if metric.scores.blank?

        count += 1
        weight_keys.each do |key|
          totals[key] += metric.scores[key].to_f
        end
      end

      return {} if count.zero?

      weight_keys.to_h { |key| [ key, (totals[key] / count).round(4) ] }
    end

    def prompt_comparison
      version_metrics = metrics.where.not(prompt_version_id: nil)
        .group(:prompt_version_id)
        .select(
          "prompt_version_id",
          "AVG(composite_score) AS avg_score",
          "COUNT(*) AS sample_size"
        )

      version_metrics.filter_map do |row|
        next if row.sample_size < 1

        version = PromptVersion.find_by(id: row.prompt_version_id)
        next unless version

        {
          prompt_version_id: row.prompt_version_id,
          prompt_name: version.prompt.name,
          version_number: version.version,
          avg_score: row.avg_score.to_f.round(4),
          sample_size: row.sample_size
        }
      end.sort_by { |r| -r[:avg_score] }
    end

    def human_feedback
      human = QualityMetric.by_project(project.id).human
      return { total: 0, merge_rate: nil, sources: {} } if human.none?

      merged_count = human.select { |m| m.scores&.dig("pr_merged")&.to_f == 1.0 }.size
      total = human.count

      {
        total: total,
        merge_rate: total.positive? ? (merged_count.to_f / total * 100).round(1) : nil,
        sources: human.group(:feedback_source).count
      }
    end
  end
end
