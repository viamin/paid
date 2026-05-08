# frozen_string_literal: true

module ConfigurationBundles
  class SurrogateModel
    include Canonicalization

    Prediction = Struct.new(
      :mean_quality_score,
      :uncertainty,
      :sample_count,
      :matched_outcomes,
      keyword_init: true
    )

    PRIOR_MEAN = 0.5
    PRIOR_WEIGHT = 1.0
    MAX_OUTCOME_ROWS = 500

    attr_reader :scope

    def initialize(project: nil, scope: nil)
      @scope = scope || self.class.default_scope_for(project)
    end

    def self.call(bundle_definition:, fingerprint: nil, **options)
      new(**options).predict(bundle_definition:, fingerprint:)
    end

    def self.default_scope_for(project)
      raise ArgumentError, "project is required when scope is not provided" unless project

      BundleOutcome
        .includes(:configuration_bundle, :agent_run)
        .joins(agent_run: :project)
        .where(agent_runs: { project_id: project.id })
        .where.not(quality_score: nil)
    end

    def predict(bundle_definition:, fingerprint: nil)
      bundle_features = feature_map(bundle_definition)
      matches = weighted_matches(
        bundle_features:,
        fingerprint:,
        scoring_context: scoring_context(bundle_features)
      )
      return empty_prediction if matches.empty?

      total_weight = matches.sum { |match| match[:weight] }
      weighted_sum = matches.sum { |match| match[:weight] * match[:quality_score] }
      weighted_mean = ((PRIOR_MEAN * PRIOR_WEIGHT) + weighted_sum) / (PRIOR_WEIGHT + total_weight)

      Prediction.new(
        mean_quality_score: weighted_mean,
        uncertainty: 1.0 / Math.sqrt(PRIOR_WEIGHT + total_weight),
        sample_count: total_weight.round(4),
        matched_outcomes: matches.size
      )
    end

    private

    def weighted_matches(bundle_features:, fingerprint:, scoring_context:)
      exact_matches = exact_matches_for(fingerprint, scoring_context:)
      return exact_matches if exact_matches.present?

      outcome_rows.filter_map do |outcome_row|
        next unless same_scoring_context?(scoring_context, outcome_row[:scoring_context])

        similarity = similarity(bundle_features, outcome_row[:features])
        next if similarity.zero?

        match_row(outcome_row[:quality_score], similarity)
      end
    end

    def exact_matches_for(fingerprint, scoring_context:)
      return [] if fingerprint.blank?

      outcome_rows_by_fingerprint.fetch(fingerprint, []).filter_map do |outcome_row|
        next unless same_scoring_context?(scoring_context, outcome_row[:scoring_context])

        match_row(outcome_row[:quality_score], 1.0)
      end
    end

    def outcome_rows
      @outcome_rows ||= begin
        rows = []

        scope.order(created_at: :desc).limit(MAX_OUTCOME_ROWS).each do |outcome|
          definition = outcome.configuration_bundle&.definition
          next unless definition.is_a?(Hash)

          rows << {
            fingerprint: outcome.configuration_bundle.fingerprint,
            features: feature_map(definition),
            quality_score: outcome.quality_score.to_f,
            scoring_context: scoring_context_for(outcome)
          }
        end

        rows
      end
    end

    def outcome_rows_by_fingerprint
      @outcome_rows_by_fingerprint ||= outcome_rows.group_by { |outcome_row| outcome_row[:fingerprint] }
    end

    def match_row(quality_score, weight)
      {
        weight: weight,
        quality_score: quality_score
      }
    end

    def empty_prediction
      Prediction.new(
        mean_quality_score: PRIOR_MEAN,
        uncertainty: 1.0,
        sample_count: 0.0,
        matched_outcomes: 0
      )
    end

    def feature_map(definition)
      experiments = definition.fetch("experiments", {}).each_with_object({}) do |(config_key, config_value), normalized|
        normalized[config_key] = experiment_feature_value(config_value)
      end

      {
        goal: definition["goal"],
        agent_type: definition["agent_type"],
        provider_id: definition["provider_id"],
        prompt_version_id: definition["prompt_version_id"],
        custom_prompt_sha256: definition["custom_prompt_sha256"],
        model_selection: canonicalize(definition["model_selection"]),
        service_container_ids: Array(definition["service_container_ids"]).sort,
        mcp_servers: normalized_mcp_servers(definition),
        experiments: experiments.sort.to_h
      }
    end

    def scoring_context(features)
      {
        goal: features[:goal]
      }
    end

    def scoring_context_for(outcome)
      {
        goal: outcome.agent_run.goal
      }
    end

    def same_scoring_context?(lhs, rhs)
      lhs == rhs
    end

    def experiment_feature_value(config_value)
      return canonicalize(config_value) unless config_value.is_a?(Hash)

      value = config_value.key?("value") ? config_value["value"] : config_value["configuration_experiment_variant_id"]
      canonicalize(value)
    end

    def normalized_mcp_servers(definition)
      Array(definition["mcp_servers"])
        .map { |snapshot| canonicalize(snapshot) }
        .sort_by { |snapshot| JSON.generate(snapshot) }
    end

    def similarity(lhs, rhs)
      comparable = 0
      matched = 0

      lhs.except(:experiments).each do |key, lhs_value|
        rhs_value = rhs[key]
        next if lhs_value.blank? && rhs_value.blank?

        comparable += 1
        matched += 1 if lhs_value == rhs_value
      end

      experiment_keys = lhs.fetch(:experiments, {}).keys | rhs.fetch(:experiments, {}).keys
      experiment_keys.each do |config_key|
        lhs_value = lhs.fetch(:experiments, {})[config_key]
        rhs_value = rhs.fetch(:experiments, {})[config_key]
        next if lhs_value.nil? && rhs_value.nil?

        comparable += 1
        matched += 1 if lhs_value == rhs_value
      end

      return 0.0 if comparable.zero?

      matched.to_f / comparable
    end
  end
end
