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
      count = outcome_count
      return empty_result(count) if count < MIN_OUTCOMES_FOR_TREND

      aggregate_row = load_aggregate_row
      period_rows = load_period_rows

      ImprovementResult.new(
        early_objective_score: float_value(aggregate_row["early_objective_score"]),
        recent_objective_score: float_value(aggregate_row["recent_objective_score"]),
        objective_improvement: compute_improvement(
          float_value(aggregate_row["early_objective_score"]),
          float_value(aggregate_row["recent_objective_score"])
        ),
        early_quality_score: float_value(aggregate_row["early_quality_score"]),
        recent_quality_score: float_value(aggregate_row["recent_quality_score"]),
        quality_improvement: compute_improvement(
          float_value(aggregate_row["early_quality_score"]),
          float_value(aggregate_row["recent_quality_score"])
        ),
        early_cost_cents: float_value(aggregate_row["early_cost_cents"]),
        recent_cost_cents: float_value(aggregate_row["recent_cost_cents"]),
        cost_change_fraction: compute_improvement(
          float_value(aggregate_row["early_cost_cents"]),
          float_value(aggregate_row["recent_cost_cents"])
        ),
        early_quality_per_dollar: float_value(aggregate_row["early_quality_per_dollar"]),
        recent_quality_per_dollar: float_value(aggregate_row["recent_quality_per_dollar"]),
        quality_per_dollar_improvement: compute_improvement(
          float_value(aggregate_row["early_quality_per_dollar"]),
          float_value(aggregate_row["recent_quality_per_dollar"])
        ),
        exploitative_avg_objective: float_value(aggregate_row["exploitative_avg_objective"]),
        exploratory_avg_objective: float_value(aggregate_row["exploratory_avg_objective"]),
        exploitative_sample_count: integer_value(aggregate_row["exploitative_sample_count"]),
        exploratory_sample_count: integer_value(aggregate_row["exploratory_sample_count"]),
        optimizer_learning_ratio: compute_improvement(
          float_value(aggregate_row["exploratory_avg_objective"]),
          float_value(aggregate_row["exploitative_avg_objective"])
        ),
        outcome_count: count,
        sufficient_data: true,
        periods: build_period_snapshots(period_rows)
      )
    end

    private

    def outcome_count
      @outcome_count ||= all_bundle_outcomes_scope.count
    end

    def load_aggregate_row
      ActiveRecord::Base.connection.select_one(aggregate_sql)
    end

    def load_period_rows
      ActiveRecord::Base.connection.select_all(period_snapshots_sql).to_a
    end

    def all_bundle_outcomes_scope
      @all_bundle_outcomes_scope ||= BundleOutcome
        .joins(:agent_run)
        .where(agent_runs: { project_id: project.id })
    end

    def aggregate_sql
      <<~SQL.squish
        WITH annotated_outcomes AS (#{annotated_outcomes_sql})
        SELECT
          AVG(objective_score) FILTER (WHERE period_index = 1) AS early_objective_score,
          AVG(objective_score) FILTER (WHERE period_index = 2) AS recent_objective_score,
          AVG(quality_score) FILTER (WHERE period_index = 1) AS early_quality_score,
          AVG(quality_score) FILTER (WHERE period_index = 2) AS recent_quality_score,
          AVG(cost_cents) FILTER (WHERE period_index = 1) AS early_cost_cents,
          AVG(cost_cents) FILTER (WHERE period_index = 2) AS recent_cost_cents,
          AVG(quality_per_dollar) FILTER (WHERE period_index = 1) AS early_quality_per_dollar,
          AVG(quality_per_dollar) FILTER (WHERE period_index = 2) AS recent_quality_per_dollar,
          AVG(objective_score) FILTER (WHERE selection_mode = 'exploitative') AS exploitative_avg_objective,
          AVG(objective_score) FILTER (WHERE selection_mode = 'exploratory') AS exploratory_avg_objective,
          COUNT(*) FILTER (WHERE selection_mode = 'exploitative') AS exploitative_sample_count,
          COUNT(*) FILTER (WHERE selection_mode = 'exploratory') AS exploratory_sample_count
        FROM annotated_outcomes
      SQL
    end

    def period_snapshots_sql
      <<~SQL.squish
        WITH annotated_outcomes AS (#{annotated_outcomes_sql})
        SELECT
          period_index,
          COUNT(*) AS outcome_count,
          AVG(objective_score) AS avg_objective_score,
          AVG(quality_score) AS avg_quality_score,
          AVG(cost_cents) AS avg_cost_cents,
          AVG(quality_per_dollar) AS avg_quality_per_dollar,
          AVG(CASE WHEN success THEN 1.0 ELSE 0.0 END) AS success_rate
        FROM annotated_outcomes
        GROUP BY period_index
        ORDER BY period_index
      SQL
    end

    def annotated_outcomes_sql
      midpoint = midpoint_count

      all_bundle_outcomes_scope
        .select(Arel.sql(<<~SQL.squish))
          bundle_outcomes.success,
          bundle_outcomes.quality_score::double precision AS quality_score,
          bundle_outcomes.cost_cents::double precision AS cost_cents,
          #{objective_score_sql} AS objective_score,
          #{quality_per_dollar_sql} AS quality_per_dollar,
          bundle_outcomes.metrics ->> 'selection_mode' AS selection_mode,
          CASE
            WHEN ROW_NUMBER() OVER (ORDER BY bundle_outcomes.created_at, bundle_outcomes.id) <= #{midpoint} THEN 1
            ELSE 2
          END AS period_index
        SQL
        .to_sql
    end

    def midpoint_count
      outcome_count / PERIODS_FOR_TREND
    end

    def objective_score_sql
      <<~SQL.squish
        COALESCE(
          NULLIF(bundle_outcomes.metrics ->> 'objective_score', '')::double precision,
          #{objective_score_fallback_sql}
        )
      SQL
    end

    def quality_per_dollar_sql
      <<~SQL.squish
        COALESCE(
          NULLIF(bundle_outcomes.metrics ->> 'quality_per_dollar', '')::double precision,
          CASE
            WHEN bundle_outcomes.quality_score IS NULL OR bundle_outcomes.cost_cents IS NULL THEN NULL
            ELSE bundle_outcomes.quality_score / GREATEST(bundle_outcomes.cost_cents / 100.0, 0.01)
          END
        )
      SQL
    end

    def optimizer_weights
      @optimizer_weights ||= begin
        configured = project_optimizer_setting("weights")
        PromptEvolution::FitnessFunction.new(samples: [], weights: configured).score.weights
      end
    end

    def reference_cost_cents
      @reference_cost_cents ||= positive_setting(
        project_optimizer_setting("reference_cost_cents"),
        PromptEvolution::FitnessFunction::DEFAULT_REFERENCE_COST_CENTS
      )
    end

    def reference_duration_seconds
      @reference_duration_seconds ||= positive_setting(
        project_optimizer_setting("reference_duration_seconds"),
        PromptEvolution::FitnessFunction::DEFAULT_REFERENCE_DURATION_SECONDS
      )
    end

    def project_optimizer_setting(*path)
      settings = project.try(:fitness_settings)
      return unless settings.is_a?(Hash)

      settings.deep_stringify_keys.dig("configuration_bundle_optimizer", *path)
    end

    def positive_setting(value, fallback)
      numeric = Float(value, exception: false)
      numeric&.positive? ? numeric : fallback.to_f
    end

    def compute_improvement(early_avg, recent_avg)
      return nil if early_avg.nil? || recent_avg.nil?
      return 0.0 if early_avg.zero?

      ((recent_avg - early_avg) / early_avg.abs).round(4)
    end

    def build_period_snapshots(rows)
      rows.map do |row|
        PeriodSnapshot.new(
          label: "Period #{integer_value(row["period_index"])}",
          outcome_count: integer_value(row["outcome_count"]),
          avg_objective_score: float_value(row["avg_objective_score"]),
          avg_quality_score: float_value(row["avg_quality_score"]),
          avg_cost_cents: float_value(row["avg_cost_cents"]),
          avg_quality_per_dollar: float_value(row["avg_quality_per_dollar"]),
          success_rate: float_value(row["success_rate"])
        )
      end
    end

    def objective_score_fallback_sql
      <<~SQL.squish
        ROUND(
          (
            (#{optimizer_weights[:quality]} * COALESCE(LEAST(GREATEST(bundle_outcomes.quality_score, 0.0), 1.0), 0.0)) +
            (#{optimizer_weights[:cost]} * #{normalized_inverse_sql("bundle_outcomes.cost_cents", reference_cost_cents)}) +
            (#{optimizer_weights[:speed]} * #{normalized_inverse_sql("bundle_outcomes.duration_seconds", reference_duration_seconds)})
          )::numeric,
          4
        )::double precision
      SQL
    end

    def normalized_inverse_sql(column_name, reference)
      <<~SQL.squish
        CASE
          WHEN #{column_name} IS NULL THEN 0.0
          ELSE #{reference} / (GREATEST(#{column_name}, 0.0) + #{reference})
        END
      SQL
    end

    def float_value(value)
      return nil if value.nil?

      value.to_f
    end

    def integer_value(value)
      return 0 if value.nil?

      value.to_i
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
