# frozen_string_literal: true

require "digest"

module ConfigurationBundles
  class Optimizer
    include BundleFingerprinting

    INVALID_VARIANT_VALUE = Object.new
    DEFAULT_EXPLORATION_BUDGETS = {
      "task" => 0.1,
      "project" => 0.25
    }.freeze
    PRIMARY_SELECTION_CONTEXT = "project"

    Selection = Struct.new(
      :definition,
      :fingerprint,
      :variant_by_experiment_id,
      :score_inputs,
      :selection_mode,
      :selection_context,
      :budget_snapshot,
      keyword_init: true
    )

    ScoreInputs = Struct.new(
      :predicted_quality_score,
      :uncertainty,
      :sample_count,
      :acquisition_score,
      keyword_init: true
    )

    EXPLORATION_WEIGHT = 0.4

    attr_reader :agent_run, :surrogate_model

    def initialize(agent_run:, surrogate_model: nil)
      @agent_run = agent_run
      @surrogate_model = surrogate_model || SurrogateModel.new(project: agent_run.project)
    end

    def self.call(...)
      new(...).select_bundle
    end

    def select_bundle
      selections = candidate_variants.map { |variant_by_experiment_id| score_candidate(variant_by_experiment_id) }
      return if selections.empty?

      exploitative = exploitative_selection(selections)
      exploratory = exploratory_selection(selections)
      return annotate_selection(exploitative, selection_mode: "exploitative", include_budget: false) unless exploratory_candidate?(exploitative, exploratory)
      return annotate_selection(exploitative, selection_mode: "exploitative") unless exploration_allowed?

      annotate_selection(exploratory, selection_mode: "exploratory")
    end

    private

    def score_candidate(variant_by_experiment_id)
      definition = bundle_definition(variant_by_experiment_id)
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(definition))
      prediction = surrogate_model.predict(bundle_definition: definition, fingerprint: fingerprint)
      acquisition_score = prediction.mean_quality_score + (EXPLORATION_WEIGHT * prediction.uncertainty)

      Selection.new(
        definition: definition,
        fingerprint: fingerprint,
        variant_by_experiment_id: variant_by_experiment_id,
        score_inputs: ScoreInputs.new(
          predicted_quality_score: prediction.mean_quality_score,
          uncertainty: prediction.uncertainty,
          sample_count: prediction.sample_count,
          acquisition_score: acquisition_score
        )
      )
    end

    def candidate_variants
      experiments = active_experiments.filter_map do |experiment|
        variants = experiment.configuration_experiment_variants.order(:id).filter_map do |variant|
          next if parsed_variant_value(variant, experiment:).equal?(INVALID_VARIANT_VALUE)

          [ experiment.id, variant ]
        end
        next if variants.empty?

        variants
      end
      return [] if experiments.empty?

      experiments.shift.product(*experiments).map do |combination|
        Array(combination).flatten(1).each_slice(2).to_h
      end
    end

    def exploitative_selection(selections)
      selections.max_by do |selection|
        [
          selection.score_inputs.predicted_quality_score,
          selection.score_inputs.acquisition_score
        ]
      end
    end

    def exploratory_selection(selections)
      selections.max_by do |selection|
        [
          selection.score_inputs.acquisition_score,
          selection.score_inputs.predicted_quality_score
        ]
      end
    end

    def exploratory_candidate?(exploitative, exploratory)
      exploitative&.fingerprint != exploratory&.fingerprint
    end

    def annotate_selection(selection, selection_mode:, include_budget: true)
      budget_snapshot = include_budget ? exploration_budget_snapshot : nil
      Selection.new(
        definition: selection.definition,
        fingerprint: selection.fingerprint,
        variant_by_experiment_id: selection.variant_by_experiment_id,
        score_inputs: selection.score_inputs,
        selection_mode: selection_mode,
        selection_context: primary_selection_context,
        budget_snapshot: budget_snapshot
      )
    end

    def exploration_allowed?
      exploration_budget_snapshot.values.all? { |snapshot| snapshot[:within_budget] }
    end

    def exploration_budget_snapshot
      @exploration_budget_snapshot ||= applicable_contexts.index_with do |context|
        total_runs, exploratory_runs = prior_run_counts_for(context)
        observed_share = total_runs.zero? ? 0.0 : exploratory_runs.to_f / total_runs
        projected_share = (exploratory_runs + 1).to_f / (total_runs + 1)
        budget = exploration_budget_for(context)

        {
          budget: budget,
          total_runs: total_runs,
          exploratory_runs: exploratory_runs,
          observed_share: observed_share.round(4),
          projected_share: projected_share.round(4),
          within_budget: budget.positive? && projected_share <= budget
        }
      end
    end

    def applicable_contexts
      contexts = [ PRIMARY_SELECTION_CONTEXT ]
      contexts.unshift("task") if agent_run.issue_id.present?
      contexts
    end

    def primary_selection_context
      agent_run.issue_id.present? ? "task" : PRIMARY_SELECTION_CONTEXT
    end

    def prior_runs_for(context)
      scope = AgentRun
        .where(project_id: agent_run.project_id, goal: agent_run.goal)
        .where.not(id: agent_run.id)
        .where.not(configuration_bundle_selection_mode: nil)

      context == "task" ? scope.where(issue_id: agent_run.issue_id) : scope
    end

    def prior_run_counts_for(context)
      prior_runs_for(context).pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COUNT(*) FILTER (WHERE configuration_bundle_selection_mode = 'exploratory')")
      )
    end

    def exploration_budget_for(context)
      raw_value = project_optimizer_setting("exploration_budgets", context) || DEFAULT_EXPLORATION_BUDGETS.fetch(context)
      budget = Float(raw_value, exception: false)
      return DEFAULT_EXPLORATION_BUDGETS.fetch(context) unless budget

      budget = budget / 100.0 if budget > 1
      budget.clamp(0.0, 1.0)
    end

    def project_optimizer_setting(*path)
      settings = agent_run.project.fitness_settings
      return unless settings.is_a?(Hash)

      settings.deep_stringify_keys.dig("configuration_bundle_optimizer", *path)
    end

    def active_experiments
      ConfigurationExperiment::TRACKED_CONFIG_KEYS.filter_map do |config_key|
        ConfigurationExperiment.active_for(config_key, project: agent_run.project, agent_run: agent_run)
      end
    end

    def bundle_definition(variant_by_experiment_id)
      canonicalize(
        {
          schema_version: 1,
          goal: agent_run.goal,
          agent_type: agent_run.agent_type,
          provider_id: agent_run.provider_id,
          prompt_version_id: agent_run.prompt_version_id,
          custom_prompt_sha256: custom_prompt_sha256,
          model_selection: model_selection_definition,
          service_container_ids: normalized_service_container_ids,
          mcp_servers: normalized_mcp_servers,
          experiments: experiment_definitions(variant_by_experiment_id)
        }.compact
      )
    end

    def experiment_definitions(variant_by_experiment_id)
      variant_by_experiment_id.each_with_object({}) do |(_, variant), definitions|
        experiment = variant.configuration_experiment
        definitions[experiment.config_key] = {
          configuration_experiment_id: experiment.id,
          configuration_experiment_variant_id: variant.id,
          value: parsed_variant_value(variant, experiment:)
        }
      end
    end

    def parsed_variant_value(variant, experiment:)
      @parsed_variant_values ||= {}
      return @parsed_variant_values[variant.id] if @parsed_variant_values.key?(variant.id)

      @parsed_variant_values[variant.id] = variant.parsed_value
    rescue StandardError => e
      Rails.logger.warn(
        message: "configuration_bundles.invalid_optimizer_variant_skipped",
        agent_run_id: agent_run.id,
        configuration_experiment_id: experiment.id,
        configuration_experiment_variant_id: variant.id,
        error_class: e.class.name,
        error: e.message
      )

      @parsed_variant_values[variant.id] = INVALID_VARIANT_VALUE
    end
  end
end
