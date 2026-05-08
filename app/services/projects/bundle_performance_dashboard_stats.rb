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
      {
        summary: summary,
        bundle_rankings: bundle_rankings,
        experiment_confidence: experiment_confidence,
        optimizer_insights: optimizer_insights,
        tradeoff_frontier: tradeoff_frontier,
        sparse: sparse?
      }
    end

    private

    def summary
      {
        bundle_count: bundle_rankings.size,
        outcome_count: bundle_outcomes_scope.count,
        active_experiment_count: active_experiments.size,
        reviewable_bundle_count: bundle_rankings.count { |bundle| !bundle[:sparse] },
        sparse_bundle_count: bundle_rankings.count { |bundle| bundle[:sparse] }
      }
    end

    def sparse?
      summary[:outcome_count].zero? && summary[:active_experiment_count].zero?
    end

    def bundle_rankings
      @bundle_rankings ||= begin
        rows = bundle_outcomes_scope
          .joins(:configuration_bundle)
          .group("configuration_bundles.id")
          .order(Arel.sql("AVG(bundle_outcomes.quality_score) DESC NULLS LAST, COUNT(bundle_outcomes.id) DESC"))
          .limit(MAX_BUNDLE_ROWS)
          .pluck(
            Arel.sql("configuration_bundles.id"),
            Arel.sql("COUNT(bundle_outcomes.id)"),
            Arel.sql("COUNT(bundle_outcomes.quality_score)"),
            Arel.sql("AVG(bundle_outcomes.quality_score)"),
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

        rows.filter_map do |bundle_id, outcome_count, quality_count, avg_quality, success_count, avg_cost, avg_duration, avg_tokens, last_seen_at|
          bundle = bundles_by_id[bundle_id]
          next unless bundle

          outcome_count = outcome_count.to_i
          quality_count = quality_count.to_i

          {
            bundle: bundle,
            outcome_count: outcome_count,
            quality_sample_count: quality_count,
            avg_quality_score: avg_quality&.to_f,
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
      active_experiments.map do |experiment|
        analysis = ConfigurationExperiments::Analyze.call(
          configuration_experiment: experiment
        )

        {
          experiment: experiment,
          config_label: experiment.config_key.tr(".", " ").titleize,
          status: analysis.status,
          confidence: analysis.confidence,
          improvement: analysis.improvement,
          winner: analysis.winner,
          min_samples_per_variant: experiment.min_samples_per_variant,
          confidence_threshold: experiment.confidence_threshold,
          variants: experiment.configuration_experiment_variants.order(:id).map do |variant|
            {
              variant: variant,
              label: variant_label(variant),
              is_control: variant.is_control,
              sample_count: variant.sample_count,
              avg_quality_score: variant.avg_quality_score&.to_f,
              sparse: variant.sample_count < experiment.min_samples_per_variant
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
      candidates = bundle_rankings.select { |bundle| bundle[:avg_quality_score].present? && bundle[:avg_cost_cents].present? }
      return [] if candidates.empty?

      pareto_bundles = candidates.reject do |bundle|
        candidates.any? do |other|
          next if other.equal?(bundle)

          other[:avg_quality_score] >= bundle[:avg_quality_score] &&
            other[:avg_cost_cents] <= bundle[:avg_cost_cents] &&
            (
              other[:avg_quality_score] > bundle[:avg_quality_score] ||
              other[:avg_cost_cents] < bundle[:avg_cost_cents]
            )
        end
      end

      pareto_bundles.sort_by { |bundle| [ -bundle[:avg_quality_score], bundle[:avg_cost_cents] ] }
    end

    def bundle_outcomes_scope
      @bundle_outcomes_scope ||= BundleOutcome
        .joins(:agent_run)
        .where(agent_runs: { project_id: project.id })
    end

    def active_experiments
      @active_experiments ||= ConfigurationExperiment
        .running
        .where(
          id: ConfigurationExperimentAssignment
            .joins(:agent_run)
            .where(agent_runs: { project_id: project.id })
            .select(:configuration_experiment_id)
        )
        .distinct
        .order(:id)
        .to_a
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
        acquisition_score: selection.score_inputs.acquisition_score.to_f,
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
  end
end
