# frozen_string_literal: true

module Projects
  class BundlePerformanceDashboardStats
    MIN_REVIEWABLE_SAMPLE_SIZE = 3
    MAX_BUNDLE_ROWS = 10
    MAX_CANDIDATES_PER_GOAL = 5

    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def call
      insights = optimizer_insights

      {
        summary: summary,
        sparse_details: sparse_details(insights),
        bundle_rankings: bundle_rankings,
        experiment_confidence: experiment_confidence,
        optimizer_insights: insights,
        tradeoff_frontier: tradeoff_frontier,
        sparse: sparse?(insights)
      }
    end

    private

    def summary
      @summary ||= begin
        counts = bundle_outcomes_scope
          .joins(:configuration_bundle)
          .group("configuration_bundles.id")
          .pluck(
            Arel.sql("configuration_bundles.id"),
            Arel.sql("COUNT(bundle_outcomes.quality_score)")
          )

        total = counts.size
        reviewable = counts.count { |_, quality_count| quality_count >= MIN_REVIEWABLE_SAMPLE_SIZE }

        {
          bundle_count: total,
          outcome_count: bundle_outcomes_scope.count,
          active_experiment_count: active_experiments.size,
          reviewable_bundle_count: reviewable,
          sparse_bundle_count: total - reviewable
        }
      end
    end

    def sparse?(insights)
      return false unless summary[:outcome_count].zero? && summary[:active_experiment_count].zero?

      insights.none? { |insight| insight[:candidates].present? }
    end

    def sparse_details(insights)
      {
        sparse_bundle_count: summary[:sparse_bundle_count],
        sparse_experiment_count: experiment_confidence.count do |experiment|
          experiment[:variants].any? { |variant| variant[:sparse] }
        end,
        sparse_goal_count: insights.count { |insight| insight[:sparse] }
      }
    end

    def bundle_rankings
      @bundle_rankings ||= begin
        rows = bundle_outcomes_scope
          .joins(:configuration_bundle)
          .group("configuration_bundles.id")
          .order(Arel.sql("#{average_objective_score_sql} DESC NULLS LAST, AVG(bundle_outcomes.quality_score) DESC NULLS LAST, COUNT(bundle_outcomes.id) DESC"))
          .limit(MAX_BUNDLE_ROWS)
          .pluck(
            Arel.sql("configuration_bundles.id"),
            Arel.sql("COUNT(bundle_outcomes.id)"),
            Arel.sql("COUNT(bundle_outcomes.quality_score)"),
            Arel.sql(average_objective_score_sql),
            Arel.sql("AVG(bundle_outcomes.quality_score)"),
            Arel.sql(average_quality_per_dollar_sql),
            Arel.sql("COUNT(*) FILTER (WHERE bundle_outcomes.success)"),
            Arel.sql("AVG(bundle_outcomes.cost_cents)"),
            Arel.sql("AVG(bundle_outcomes.duration_seconds)"),
            Arel.sql("AVG(bundle_outcomes.tokens_used)"),
            Arel.sql("MAX(bundle_outcomes.created_at)")
          )

        bundles_by_id = ConfigurationBundle
          .includes(:prompt_version)
          .where(id: rows.map(&:first))
          .index_by(&:id)

        rows.filter_map do |bundle_id, outcome_count, quality_count, avg_objective, avg_quality, avg_quality_per_dollar, success_count, avg_cost, avg_duration, avg_tokens, last_seen_at|
          bundle = bundles_by_id[bundle_id]
          next unless bundle

          outcome_count = outcome_count.to_i
          quality_count = quality_count.to_i

          {
            bundle: bundle,
            outcome_count: outcome_count,
            quality_sample_count: quality_count,
            avg_objective_score: avg_objective&.to_f,
            avg_quality_score: avg_quality&.to_f,
            avg_quality_per_dollar: avg_quality_per_dollar&.to_f,
            success_rate: outcome_count.zero? ? nil : success_count.to_f / outcome_count,
            avg_cost_cents: avg_cost&.to_f&.round,
            avg_duration_seconds: avg_duration&.to_f&.round,
            avg_tokens_used: avg_tokens&.to_f&.round,
            last_seen_at: last_seen_at,
            sparse: quality_count < MIN_REVIEWABLE_SAMPLE_SIZE,
            experiment_values: experiment_values(bundle.definition)
          }
        end
      end
    end

    def experiment_confidence
      @experiment_confidence ||= active_experiments.map do |experiment|
        variant_stats = project_scoped_variant_stats(experiment)
        variants = experiment_variants_by_experiment_id.fetch(experiment.id, [])

        analysis = project_scoped_analysis(experiment, variant_stats, variants: variants)

        {
          experiment: experiment,
          config_label: experiment.config_key.tr(".", " ").titleize,
          status: analysis.status,
          confidence: analysis.confidence,
          improvement: analysis.improvement,
          winner: analysis.winner,
          winner_label: analysis.winner ? variant_label(analysis.winner) : nil,
          min_samples_per_variant: experiment.min_samples_per_variant,
          confidence_threshold: experiment.confidence_threshold,
          variants: variants.map do |variant|
            stats = variant_stats[variant.id] || { sample_count: 0, avg_quality_score: nil }

            {
              variant: variant,
              label: variant_label(variant),
              is_control: variant.is_control,
              sample_count: stats[:sample_count],
              avg_quality_score: stats[:avg_quality_score],
              sparse: stats[:sample_count] < experiment.min_samples_per_variant
            }
          end
        }
      end
    end

    def optimizer_insights
      AgentRun::GOALS.map do |goal|
        representative_run = representative_runs_by_goal[goal]
        next missing_run_insight(goal) unless representative_run

        candidates = ConfigurationBundles::Optimizer.ranked_candidates(agent_run: representative_run)
        {
          goal: goal,
          representative_run: representative_run,
          candidates: candidates.first(MAX_CANDIDATES_PER_GOAL).map { |selection| candidate_summary(selection) },
          sparse: candidates.empty? || candidates.all? { |selection| selection.score_inputs.sample_count < MIN_REVIEWABLE_SAMPLE_SIZE }
        }
      end
    end

    def tradeoff_frontier
      candidates = all_bundle_quality_cost.select { |b| b[:avg_objective_score].present? && b[:avg_cost_cents].present? }
      return [] if candidates.empty?

      pareto_bundles = candidates.reject do |bundle|
        candidates.any? do |other|
          next if other.equal?(bundle)

          other[:avg_objective_score] >= bundle[:avg_objective_score] &&
            other[:avg_cost_cents] <= bundle[:avg_cost_cents] &&
            (
              other[:avg_objective_score] > bundle[:avg_objective_score] ||
              other[:avg_cost_cents] < bundle[:avg_cost_cents]
            )
        end
      end

      pareto_bundles.sort_by { |bundle| [ -bundle[:avg_objective_score], bundle[:avg_cost_cents] ] }
    end

    def all_bundle_quality_cost
      @all_bundle_quality_cost ||= begin
        rows = bundle_outcomes_scope
          .joins(:configuration_bundle)
          .group("configuration_bundles.id")
          .pluck(
            Arel.sql("configuration_bundles.id"),
            Arel.sql(average_objective_score_sql),
            Arel.sql("AVG(bundle_outcomes.quality_score)"),
            Arel.sql("AVG(bundle_outcomes.cost_cents)"),
            Arel.sql("AVG(bundle_outcomes.tokens_used)")
          )

        bundles_by_id = ConfigurationBundle
          .where(id: rows.map(&:first))
          .index_by(&:id)

        rows.filter_map do |bundle_id, avg_objective, avg_quality, avg_cost, avg_tokens|
          bundle = bundles_by_id[bundle_id]
          next unless bundle

          {
            bundle: bundle,
            avg_objective_score: avg_objective&.to_f,
            avg_quality_score: avg_quality&.to_f,
            avg_cost_cents: avg_cost&.to_f&.round,
            avg_tokens_used: avg_tokens&.to_f&.round
          }
        end
      end
    end

    def bundle_outcomes_scope
      @bundle_outcomes_scope ||= BundleOutcome
        .joins(:agent_run)
        .where(agent_runs: { project_id: project.id })
    end

    def project_scoped_variant_stats(experiment)
      rows = ConfigurationExperimentAssignment
        .joins(:agent_run)
        .where(agent_runs: { project_id: project.id })
        .where(configuration_experiment_id: experiment.id)
        .group(:configuration_experiment_variant_id)
        .pluck(
          Arel.sql("configuration_experiment_variant_id"),
          Arel.sql("COUNT(quality_score)"),
          Arel.sql("AVG(quality_score)")
        )

      rows.to_h do |variant_id, count, avg_score|
        [ variant_id, { sample_count: count.to_i, avg_quality_score: avg_score&.to_f } ]
      end
    end

    def project_scoped_analysis(experiment, variant_stats, variants: nil)
      variants ||= experiment_variants_by_experiment_id.fetch(experiment.id, [])
      control = variants.find(&:is_control)

      return ConfigurationExperiments::Analyze::Result.new(status: :insufficient_data) unless control

      all_ready = variants.all? do |v|
        (variant_stats.dig(v.id, :sample_count) || 0) >= experiment.min_samples_per_variant
      end
      return ConfigurationExperiments::Analyze::Result.new(status: :insufficient_data) unless all_ready

      control_scores = project_scoped_scores(control)
      return ConfigurationExperiments::Analyze::Result.new(status: :insufficient_data) if control_scores.size < 2

      results = variants.reject(&:is_control).filter_map do |variant|
        variant_scores = project_scoped_scores(variant)
        next if variant_scores.size < 2

        t_result = AbTests::Statistics.welch_t_test(control_scores, variant_scores)
        {
          variant: variant,
          mean_diff: AbTests::Statistics.mean(variant_scores) - AbTests::Statistics.mean(control_scores),
          p_value: t_result[:p_value],
          significant: t_result[:p_value] < (1 - experiment.confidence_threshold)
        }
      end

      determine_experiment_outcome(results)
    end

    def project_scoped_scores(variant)
      ConfigurationExperimentAssignment
        .joins(:agent_run)
        .where(agent_runs: { project_id: project.id })
        .where(configuration_experiment_variant_id: variant.id)
        .where.not(quality_score: nil)
        .pluck(:quality_score)
        .map(&:to_f)
    end

    def determine_experiment_outcome(results)
      return ConfigurationExperiments::Analyze::Result.new(status: :insufficient_data) if results.empty?

      significant_improvements = results.select { |r| r[:significant] && r[:mean_diff] > 0 }

      if significant_improvements.any?
        winner = significant_improvements.max_by { |r| r[:mean_diff] }
        ConfigurationExperiments::Analyze::Result.new(
          status: :winner_found,
          winner: winner[:variant],
          confidence: 1 - winner[:p_value],
          improvement: winner[:mean_diff],
          details: results
        )
      elsif results.all? { |r| r[:significant] && r[:mean_diff] < 0 }
        ConfigurationExperiments::Analyze::Result.new(status: :control_wins, details: results)
      else
        ConfigurationExperiments::Analyze::Result.new(status: :no_significant_difference, details: results)
      end
    end

    def active_experiments
      @active_experiments ||= begin
        assignment_backed_by_key = assignment_backed_active_experiments.index_by(&:config_key)

        ConfigurationExperiment::TRACKED_CONFIG_KEYS.filter_map do |config_key|
          ConfigurationExperiment.active_for(config_key, project: project) ||
            assignment_backed_by_key[config_key]
        end
          .sort_by { |experiment| active_experiment_sort_key(experiment) }
      end
    end

    def assignment_backed_active_experiments
      experiment_scope_for_project
        .joins(configuration_experiment_assignments: :agent_run)
        .where(agent_runs: { project_id: project.id })
        .distinct
        .to_a
    end

    def experiment_scope_for_project
      ConfigurationExperiment
        .running
        .where(config_key: ConfigurationExperiment::TRACKED_CONFIG_KEYS)
        .where(account_id: [ project.account_id, nil ])
    end

    def active_experiment_sort_key(experiment)
      [
        ConfigurationExperiment::TRACKED_CONFIG_KEYS.index(experiment.config_key) || ConfigurationExperiment::TRACKED_CONFIG_KEYS.length,
        experiment.account_id == project.account_id ? 0 : 1,
        experiment.id
      ]
    end

    def experiment_variants_by_experiment_id
      @experiment_variants_by_experiment_id ||= ConfigurationExperimentVariant
        .where(configuration_experiment_id: active_experiments.map(&:id))
        .order(:configuration_experiment_id, :id)
        .to_a
        .group_by(&:configuration_experiment_id)
    end

    def representative_runs_by_goal
      @representative_runs_by_goal ||= project.agent_runs
        .where(goal: AgentRun::GOALS)
        .select("DISTINCT ON (goal) agent_runs.*")
        .order(:goal, created_at: :desc)
        .index_by(&:goal)
    end

    def candidate_summary(selection)
      uncertainty = selection.score_inputs.uncertainty.to_f

      {
        acquisition_function: selection.score_inputs.acquisition_function,
        acquisition_score: selection.score_inputs.acquisition_score.to_f,
        best_observed_objective_score: selection.score_inputs.best_observed_objective_score.to_f,
        predicted_objective_score: selection.score_inputs.predicted_objective_score.to_f,
        predicted_quality_score: selection.score_inputs.predicted_quality_score.to_f,
        uncertainty: uncertainty,
        confidence_proxy: 1.0 - uncertainty.clamp(0.0, 1.0),
        sample_count: selection.score_inputs.sample_count.to_f,
        experiment_values: experiment_values(selection.definition)
      }
    end

    def missing_run_insight(goal)
      {
        goal: goal,
        representative_run: nil,
        candidates: [],
        sparse: true
      }
    end

    def experiment_values(definition)
      definition.fetch("experiments", {}).map do |config_key, config_value|
        value = config_value.is_a?(Hash) ? config_value["value"] : config_value
        "#{config_key}=#{value.inspect}"
      end
    end

    def variant_label(variant)
      parsed_value = variant.parsed_value
      prefix = variant.is_control ? "Control" : "Variant"
      "#{prefix}: #{parsed_value.inspect}"
    rescue JSON::ParserError
      "#{variant.is_control ? 'Control' : 'Variant'}: invalid JSON"
    end

    def average_objective_score_sql
      <<~SQL.squish
        AVG(
          COALESCE(
            NULLIF(bundle_outcomes.metrics ->> 'objective_score', '')::double precision,
            #{objective_score_fallback_sql}
          )
        )
      SQL
    end

    def average_quality_per_dollar_sql
      <<~SQL.squish
        AVG(
          COALESCE(
            NULLIF(bundle_outcomes.metrics ->> 'quality_per_dollar', '')::double precision,
            CASE
              WHEN bundle_outcomes.quality_score IS NULL OR bundle_outcomes.cost_cents IS NULL THEN NULL
              ELSE bundle_outcomes.quality_score / GREATEST(bundle_outcomes.cost_cents / 100.0, 0.01)
            END
          )
        )
      SQL
    end

    def objective_score_fallback_sql
      <<~SQL.squish
        ROUND(
          (
            (#{optimizer_weights[:quality]} * COALESCE(LEAST(GREATEST(bundle_outcomes.quality_score, 0.0), 1.0), 0.0)) +
            (#{optimizer_weights[:cost]} * #{normalized_inverse_sql("bundle_outcomes.cost_cents", optimizer_reference_cost_cents)}) +
            (#{optimizer_weights[:speed]} * #{normalized_inverse_sql("bundle_outcomes.duration_seconds", optimizer_reference_duration_seconds)})
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

    def optimizer_weights
      @optimizer_weights ||= begin
        configured = project_optimizer_setting("weights")
        PromptEvolution::FitnessFunction.new(samples: [], weights: configured)
          .score
          .weights
      end
    end

    def optimizer_reference_cost_cents
      @optimizer_reference_cost_cents ||= positive_optimizer_setting(
        project_optimizer_setting("reference_cost_cents"),
        PromptEvolution::FitnessFunction::DEFAULT_REFERENCE_COST_CENTS
      )
    end

    def optimizer_reference_duration_seconds
      @optimizer_reference_duration_seconds ||= positive_optimizer_setting(
        project_optimizer_setting("reference_duration_seconds"),
        PromptEvolution::FitnessFunction::DEFAULT_REFERENCE_DURATION_SECONDS
      )
    end

    def project_optimizer_setting(*path)
      settings = project.fitness_settings
      return unless settings.is_a?(Hash)

      settings.deep_stringify_keys.dig("configuration_bundle_optimizer", *path)
    end

    def positive_optimizer_setting(value, fallback)
      numeric = Float(value, exception: false)
      numeric&.positive? ? numeric : fallback.to_f
    end
  end
end
