# frozen_string_literal: true

module ConfigurationBundles
  class OutcomeImprovement
    MIN_OUTCOMES_FOR_TREND = 4
    PERIODS_FOR_TREND = 2

    ImprovementResult = Struct.new(
      :early_objective_score,
      :recent_objective_score,
      :objective_improvement,
      :early_quality_score,
      :recent_quality_score,
      :quality_improvement,
      :early_cost_cents,
      :recent_cost_cents,
      :cost_change_fraction,
      :early_quality_per_dollar,
      :recent_quality_per_dollar,
      :quality_per_dollar_improvement,
      :exploitative_avg_objective,
      :exploratory_avg_objective,
      :exploitative_sample_count,
      :exploratory_sample_count,
      :optimizer_learning_ratio,
      :outcome_count,
      :sufficient_data,
      :periods,
      keyword_init: true
    )

    PeriodSnapshot = Struct.new(
      :label,
      :outcome_count,
      :avg_objective_score,
      :avg_quality_score,
      :avg_cost_cents,
      :avg_quality_per_dollar,
      :success_rate,
      keyword_init: true
    )

    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def call
      rows = load_outcome_rows
      return empty_result(rows.size) if rows.size < MIN_OUTCOMES_FOR_TREND

      early, recent = split_rows(rows)
      exploitative, exploratory = partition_by_selection_mode(rows)

      ImprovementResult.new(
        early_objective_score: average(early, :objective_score),
        recent_objective_score: average(recent, :objective_score),
        objective_improvement: compute_improvement(early, recent, :objective_score),
        early_quality_score: average(early, :quality_score),
        recent_quality_score: average(recent, :quality_score),
        quality_improvement: compute_improvement(early, recent, :quality_score),
        early_cost_cents: average(early, :cost_cents),
        recent_cost_cents: average(recent, :cost_cents),
        cost_change_fraction: compute_cost_change(early, recent),
        early_quality_per_dollar: average_quality_per_dollar(early),
        recent_quality_per_dollar: average_quality_per_dollar(recent),
        quality_per_dollar_improvement: compute_quality_per_dollar_improvement(early, recent),
        exploitative_avg_objective: average(exploitative, :objective_score),
        exploratory_avg_objective: average(exploratory, :objective_score),
        exploitative_sample_count: exploitative.size,
        exploratory_sample_count: exploratory.size,
        optimizer_learning_ratio: compute_optimizer_learning_ratio(exploitative, exploratory),
        outcome_count: rows.size,
        sufficient_data: true,
        periods: build_period_snapshots(rows)
      )
    end

    private

    def load_outcome_rows
      BundleOutcome
        .joins(:agent_run)
        .where(agent_runs: { project_id: project.id })
        .where.not(quality_score: nil)
        .order(:created_at)
        .pluck(
          Arel.sql(<<~SQL.squish)
            bundle_outcomes.quality_score,
            bundle_outcomes.cost_cents,
            bundle_outcomes.success,
            bundle_outcomes.metrics->>'objective_score',
            bundle_outcomes.metrics->>'quality_per_dollar',
            bundle_outcomes.metrics->>'selection_mode',
            bundle_outcomes.created_at
          SQL
        )
        .map { |row| parse_row(row) }
    end

    def parse_row(row)
      quality_score, cost_cents, success, objective_raw, qpd_raw, selection_mode, created_at = row
      {
        quality_score: quality_score.to_f,
        cost_cents: cost_cents.to_i,
        success: success,
        objective_score: objective_raw.present? ? objective_raw.to_f : nil,
        quality_per_dollar: qpd_raw.present? ? qpd_raw.to_f : nil,
        selection_mode: selection_mode,
        created_at: created_at
      }
    end

    def split_rows(rows)
      midpoint = rows.size / 2
      [ rows[0...midpoint], rows[midpoint..] ]
    end

    def partition_by_selection_mode(rows)
      exploitative = rows.select { |r| r[:selection_mode] == "exploitative" }
      exploratory = rows.select { |r| r[:selection_mode] == "exploratory" }
      [ exploitative, exploratory ]
    end

    def average(rows, key)
      values = rows.filter_map { |r| r[key] }
      return nil if values.empty?

      values.sum.to_f / values.size
    end

    def compute_improvement(early, recent, key)
      early_avg = average(early, key)
      recent_avg = average(recent, key)
      return nil if early_avg.nil? || recent_avg.nil?
      return 0.0 if early_avg.zero?

      ((recent_avg - early_avg) / early_avg.abs).round(4)
    end

    def compute_cost_change(early, recent)
      early_cost = average(early, :cost_cents)
      recent_cost = average(recent, :cost_cents)
      return nil if early_cost.nil? || recent_cost.nil?
      return 0.0 if early_cost.zero?

      ((recent_cost - early_cost) / early_cost.abs).round(4)
    end

    def average_quality_per_dollar(rows)
      values = rows.filter_map { |r| compute_quality_per_dollar(r) }
      return nil if values.empty?

      values.sum.to_f / values.size
    end

    def compute_quality_per_dollar(row)
      return row[:quality_per_dollar] if row[:quality_per_dollar].present?
      return nil if row[:cost_cents].nil? || row[:cost_cents].zero?

      row[:quality_score].to_f / (row[:cost_cents].to_f / 100.0)
    end

    def compute_quality_per_dollar_improvement(early, recent)
      early_qpd = average_quality_per_dollar(early)
      recent_qpd = average_quality_per_dollar(recent)
      return nil if early_qpd.nil? || recent_qpd.nil?
      return 0.0 if early_qpd.zero?

      ((recent_qpd - early_qpd) / early_qpd.abs).round(4)
    end

    def compute_optimizer_learning_ratio(exploitative, exploratory)
      return nil if exploitative.empty? || exploratory.empty?

      exp_avg = average(exploitative, :objective_score)
      expl_avg = average(exploratory, :objective_score)
      return nil if exp_avg.nil? || expl_avg.nil?
      return 0.0 if expl_avg.zero?

      ((exp_avg - expl_avg) / expl_avg.abs).round(4)
    end

    def build_period_snapshots(rows)
      period_size = [ rows.size / PERIODS_FOR_TREND, 1 ].max
      rows.each_slice(period_size).each_with_index.map do |period_rows, index|
        PeriodSnapshot.new(
          label: "Period #{index + 1}",
          outcome_count: period_rows.size,
          avg_objective_score: average(period_rows, :objective_score),
          avg_quality_score: average(period_rows, :quality_score),
          avg_cost_cents: average(period_rows, :cost_cents),
          avg_quality_per_dollar: average_quality_per_dollar(period_rows),
          success_rate: success_rate_for(period_rows)
        )
      end
    end

    def success_rate_for(rows)
      return nil if rows.empty?

      rows.count { |r| r[:success] }.to_f / rows.size
    end

    def empty_result(count)
      ImprovementResult.new(
        early_objective_score: nil,
        recent_objective_score: nil,
        objective_improvement: nil,
        early_quality_score: nil,
        recent_quality_score: nil,
        quality_improvement: nil,
        early_cost_cents: nil,
        recent_cost_cents: nil,
        cost_change_fraction: nil,
        early_quality_per_dollar: nil,
        recent_quality_per_dollar: nil,
        quality_per_dollar_improvement: nil,
        exploitative_avg_objective: nil,
        exploratory_avg_objective: nil,
        exploitative_sample_count: 0,
        exploratory_sample_count: 0,
        optimizer_learning_ratio: nil,
        outcome_count: count,
        sufficient_data: false,
        periods: []
      )
    end
  end
end
