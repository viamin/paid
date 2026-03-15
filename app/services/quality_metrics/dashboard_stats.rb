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
      scored = metrics.with_scores
      {
        total_metrics: metrics.count,
        scored_metrics: scored.count,
        avg_quality_score: scored.average(:quality_score)&.round(2) || 0.0,
        pr_merge_rate: merge_rate,
        ci_pass_rate: ci_rate,
        avg_iterations: metrics.where("iterations_to_complete > 0").average(:iterations_to_complete)&.round(1) || 0.0
      }
    end

    def merge_rate
      with_pr = metrics.where.not(pr_merged: nil)
      total = with_pr.count
      return 0.0 if total.zero?

      (with_pr.where(pr_merged: true).count.to_f / total * 100).round(1)
    end

    def ci_rate
      with_ci = metrics.where.not(ci_passed: nil)
      total = with_ci.count
      return 0.0 if total.zero?

      (with_ci.where(ci_passed: true).count.to_f / total * 100).round(1)
    end

    def by_prompt
      metrics
        .joins(agent_run: :prompt_version)
        .joins("INNER JOIN prompts ON prompts.id = prompt_versions.prompt_id")
        .where.not(quality_score: nil)
        .group("prompts.name")
        .select(
          "prompts.name",
          "AVG(quality_metrics.quality_score) as avg_score",
          "COUNT(*) as sample_count"
        )
        .order("avg_score DESC")
        .limit(10)
        .map { |r| { name: r.name, avg_score: r.avg_score.to_f.round(2), sample_count: r.sample_count } }
    end

    def by_model
      metrics
        .joins(agent_run: { model_selection: :llm_model })
        .where.not(quality_score: nil)
        .group("llm_models.display_name")
        .select(
          "llm_models.display_name",
          "AVG(quality_metrics.quality_score) as avg_score",
          "COUNT(*) as sample_count"
        )
        .order("avg_score DESC")
        .map { |r| { name: r.display_name, avg_score: r.avg_score.to_f.round(2), sample_count: r.sample_count } }
    end

    def weekly_trend
      metrics
        .with_scores
        .where("quality_metrics.created_at >= ?", 12.weeks.ago)
        .group("date_trunc('week', quality_metrics.created_at)")
        .order(Arel.sql("date_trunc('week', quality_metrics.created_at)"))
        .pluck(
          Arel.sql("date_trunc('week', quality_metrics.created_at)"),
          Arel.sql("AVG(quality_metrics.quality_score)"),
          Arel.sql("COUNT(*)")
        )
        .map { |week, avg, count| { week: week.to_date, avg_score: avg.to_f.round(2), count: count } }
    end

    def score_distribution
      buckets = { "0.0-0.2" => 0, "0.2-0.4" => 0, "0.4-0.6" => 0, "0.6-0.8" => 0, "0.8-1.0" => 0 }
      metrics.with_scores.pluck(:quality_score).each do |score|
        bucket = case score.to_f
        when 0.0...0.2 then "0.0-0.2"
        when 0.2...0.4 then "0.2-0.4"
        when 0.4...0.6 then "0.4-0.6"
        when 0.6...0.8 then "0.6-0.8"
        else "0.8-1.0"
        end
        buckets[bucket] += 1
      end
      buckets
    end
  end
end
