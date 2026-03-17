# frozen_string_literal: true

module QualityMetrics
  class DashboardStats
    attr_reader :account

    def self.call(...)
      new(...).call
    end

    def initialize(account:)
      @account = account
    end

    def call
      {
        overview: overview,
        by_prompt: by_prompt,
        by_model: by_model,
        weekly_trend: weekly_trend,
        score_distribution: score_distribution
      }
    end

    private

    def metrics
      @metrics ||= QualityMetric
        .joins(agent_run: :project)
        .where(projects: { account_id: account.id })
    end

    def overview
      scored = metrics.with_composite_score
      {
        total_metrics: metrics.count,
        scored_metrics: scored.count,
        avg_quality_score: scored.average(:composite_score)&.round(2) || 0.0
      }
    end

    def by_prompt
      metrics
        .joins(agent_run: { prompt_version: :prompt })
        .where.not(composite_score: nil)
        .group("prompts.id", "prompts.name")
        .select(
          "prompts.id as prompt_id",
          "prompts.name",
          "AVG(quality_metrics.composite_score) as avg_score",
          "COUNT(*) as sample_count"
        )
        .order("avg_score DESC")
        .limit(10)
        .map { |r| { id: r.prompt_id, name: r.name, avg_score: r.avg_score.to_f.round(2), sample_count: r.sample_count.to_i } }
    end

    def by_model
      metrics
        .joins(agent_run: { model_selection: :llm_model })
        .where.not(composite_score: nil)
        .group("llm_models.id", "llm_models.display_name")
        .select(
          "llm_models.id as llm_model_id",
          "llm_models.display_name",
          "AVG(quality_metrics.composite_score) as avg_score",
          "COUNT(*) as sample_count"
        )
        .order("avg_score DESC")
        .map { |r| { id: r.llm_model_id, name: r.display_name, avg_score: r.avg_score.to_f.round(2), sample_count: r.sample_count.to_i } }
    end

    def weekly_trend
      metrics
        .with_composite_score
        .where("quality_metrics.created_at >= ?", 12.weeks.ago)
        .group("date_trunc('week', quality_metrics.created_at)")
        .order(Arel.sql("date_trunc('week', quality_metrics.created_at)"))
        .pluck(
          Arel.sql("date_trunc('week', quality_metrics.created_at)"),
          Arel.sql("AVG(quality_metrics.composite_score)"),
          Arel.sql("COUNT(*)")
        )
        .map { |week, avg, count| { week: week.to_date, avg_score: avg.to_f.round(2), count: count } }
    end

    def score_distribution
      defaults = { "0.0-0.2" => 0, "0.2-0.4" => 0, "0.4-0.6" => 0, "0.6-0.8" => 0, "0.8-1.0" => 0 }

      rows = metrics.with_composite_score
        .group(Arel.sql(<<~SQL.squish))
          CASE
            WHEN composite_score < 0.2 THEN '0.0-0.2'
            WHEN composite_score < 0.4 THEN '0.2-0.4'
            WHEN composite_score < 0.6 THEN '0.4-0.6'
            WHEN composite_score < 0.8 THEN '0.6-0.8'
            ELSE '0.8-1.0'
          END
        SQL
        .count

      defaults.merge(rows)
    end
  end
end
