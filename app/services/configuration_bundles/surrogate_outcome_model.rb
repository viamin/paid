# frozen_string_literal: true

module ConfigurationBundles
  # @spec BUNDLE-OPT-002
  class SurrogateOutcomeModel
    Prediction = Struct.new(
      :predicted_objective_score,
      :predicted_quality_score,
      :predicted_success_probability,
      :predicted_cost_cents,
      :predicted_duration_seconds,
      :uncertainty,
      :sample_count,
      :trained_at,
      keyword_init: true
    )

    TrainedState = Struct.new(
      :rows,
      :training_size,
      :trained_at,
      :global_mean_objective,
      :global_mean_quality,
      :global_success_rate,
      keyword_init: true
    )

    PRIOR_MEAN = 0.5
    PRIOR_WEIGHT = 1.0

    attr_reader :trained_state

    def initialize(trained_state: nil)
      @trained_state = self.class.deserialize_trained_state(trained_state)
    end

    def self.train(dataset:)
      new.train(dataset:)
    end

    def self.call(bundle_definition:, trained_state:)
      new(trained_state:).predict(bundle_definition:)
    end

    def self.serialize_trained_state(trained_state)
      state = deserialize_trained_state(trained_state)
      return if state.nil?

      {
        rows: state.rows.map do |row|
          {
            features: serialize_features(row.features),
            quality_score: row.quality_score,
            objective_score: row.objective_score,
            success: row.success,
            cost_cents: row.cost_cents,
            duration_seconds: row.duration_seconds,
            tokens_used: row.tokens_used,
            weight: row.weight
          }
        end,
        training_size: state.training_size,
        trained_at: state.trained_at&.iso8601(9),
        global_mean_objective: state.global_mean_objective,
        global_mean_quality: state.global_mean_quality,
        global_success_rate: state.global_success_rate
      }
    end

    def self.deserialize_trained_state(trained_state)
      case trained_state
      when nil, TrainedState
        trained_state
      when Hash
        state_hash = trained_state.deep_stringify_keys
        TrainedState.new(
          rows: Array(state_hash["rows"]).map { |row| deserialize_row(row) },
          training_size: state_hash["training_size"],
          trained_at: deserialize_time(state_hash["trained_at"]),
          global_mean_objective: state_hash["global_mean_objective"],
          global_mean_quality: state_hash["global_mean_quality"],
          global_success_rate: state_hash["global_success_rate"]
        )
      else
        raise ArgumentError, "unsupported trained_state payload: #{trained_state.class.name}"
      end
    end

    def train(dataset:)
      rows = dataset.rows
      @trained_state = if rows.empty?
        empty_trained_state
      else
        total_weight = rows.sum(&:weight)
        TrainedState.new(
          rows: rows,
          training_size: rows.size,
          trained_at: Time.current,
          global_mean_objective: weighted_mean(rows.map(&:objective_score), rows.map(&:weight), total_weight),
          global_mean_quality: weighted_mean(rows.map(&:quality_score), rows.map(&:weight), total_weight),
          global_success_rate: weighted_mean(rows.map { |r| r.success ? 1.0 : 0.0 }, rows.map(&:weight), total_weight)
        )
      end

      self
    end

    def predict(bundle_definition:)
      return prior_prediction unless trained_state&.rows&.any?

      query_features = FeatureExtractor.call(bundle_definition)
      matches = find_matches(query_features)

      return goal_baseline_prediction(query_features.goal) if matches.empty?

      weighted_prediction(query_features, matches)
    end

    def trained?
      trained_state&.rows&.any? == true
    end

    private

    def self.serialize_features(features)
      {
        goal: features.goal,
        agent_type: features.agent_type,
        provider_id: features.provider_id,
        prompt_version_id: features.prompt_version_id,
        custom_prompt_sha256: features.custom_prompt_sha256,
        model_selection: features.model_selection,
        has_model_selection: features.has_model_selection,
        has_custom_prompt: features.has_custom_prompt,
        has_mcp_servers: features.has_mcp_servers,
        service_container_ids: features.service_container_ids,
        mcp_servers: features.mcp_servers,
        service_container_count: features.service_container_count,
        mcp_server_count: features.mcp_server_count,
        experiment_features: features.experiment_features
      }
    end

    def self.deserialize_row(row)
      row_hash = row.deep_stringify_keys

      TrainingDataset::Row.new(
        features: deserialize_features(row_hash["features"]),
        quality_score: row_hash["quality_score"],
        objective_score: row_hash["objective_score"],
        success: row_hash["success"],
        cost_cents: row_hash["cost_cents"],
        duration_seconds: row_hash["duration_seconds"],
        tokens_used: row_hash["tokens_used"],
        weight: row_hash["weight"]
      )
    end

    def self.deserialize_features(features)
      feature_hash = features.deep_stringify_keys

      FeatureExtractor::FeatureVector.new(
        goal: feature_hash["goal"],
        agent_type: feature_hash["agent_type"],
        provider_id: feature_hash["provider_id"],
        prompt_version_id: feature_hash["prompt_version_id"],
        custom_prompt_sha256: feature_hash["custom_prompt_sha256"],
        model_selection: feature_hash["model_selection"],
        has_model_selection: feature_hash["has_model_selection"],
        has_custom_prompt: feature_hash["has_custom_prompt"],
        has_mcp_servers: feature_hash["has_mcp_servers"],
        service_container_ids: feature_hash["service_container_ids"],
        mcp_servers: feature_hash["mcp_servers"],
        service_container_count: feature_hash["service_container_count"],
        mcp_server_count: feature_hash["mcp_server_count"],
        experiment_features: feature_hash["experiment_features"] || {}
      )
    end

    def self.deserialize_time(value)
      return value if value.is_a?(Time)
      return if value.blank?

      Time.iso8601(value)
    end

    def find_matches(query_features)
      trained_state.rows.filter_map do |row|
        next unless compatible_context?(query_features, row.features)

        similarity = compute_similarity(query_features, row.features)
        next if similarity <= 0

        { row: row, similarity: similarity }
      end
    end

    def compatible_context?(query, historical)
      query.goal == historical.goal &&
        query.provider_id == historical.provider_id &&
        query.prompt_version_id == historical.prompt_version_id &&
        query.custom_prompt_sha256 == historical.custom_prompt_sha256 &&
        query.model_selection == historical.model_selection &&
        query.service_container_ids == historical.service_container_ids &&
        query.mcp_servers == historical.mcp_servers
    end

    def compute_similarity(query, historical)
      scores = [
        boolean_similarity(query.agent_type, historical.agent_type),
        boolean_similarity(query.has_model_selection, historical.has_model_selection),
        boolean_similarity(query.has_custom_prompt, historical.has_custom_prompt),
        boolean_similarity(query.has_mcp_servers, historical.has_mcp_servers)
      ]

      exp_sim = experiment_similarity(query.experiment_features, historical.experiment_features)
      scores << exp_sim if exp_sim

      scores.sum.to_f / scores.size
    end

    def boolean_similarity(query_val, historical_val)
      query_val == historical_val ? 1.0 : 0.0
    end

    def experiment_similarity(query_experiments, historical_experiments)
      all_keys = query_experiments.keys | historical_experiments.keys
      return nil if all_keys.empty?

      comparable = 0
      similarity_sum = 0.0

      all_keys.each do |key|
        q_val = query_experiments[key]
        h_val = historical_experiments[key]
        next if q_val.nil? && h_val.nil?

        comparable += 1
        similarity_sum += experiment_value_similarity(q_val, h_val)
      end

      return nil if comparable.zero?
      similarity_sum / comparable
    end

    def experiment_value_similarity(query_value, historical_value)
      return 0.0 if query_value.nil? || historical_value.nil?

      if query_value.is_a?(Numeric) && historical_value.is_a?(Numeric)
        diff = (query_value - historical_value).abs
        range = [ query_value.abs, historical_value.abs, 1.0 ].max
        return Math.exp(-diff / range)
      end

      query_value == historical_value ? 1.0 : 0.0
    end

    def weighted_prediction(_query_features, matches)
      total_sim_weight = matches.sum { |m| m[:similarity] * m[:row].weight }
      denom = PRIOR_WEIGHT + total_sim_weight

      weighted_objective = matches.sum { |m| m[:similarity] * m[:row].weight * m[:row].objective_score }
      weighted_quality = matches.sum { |m| m[:similarity] * m[:row].weight * m[:row].quality_score }
      weighted_success = matches.sum { |m| m[:similarity] * m[:row].weight * (m[:row].success ? 1.0 : 0.0) }

      Prediction.new(
        predicted_objective_score: (PRIOR_MEAN * PRIOR_WEIGHT + weighted_objective) / denom,
        predicted_quality_score: (PRIOR_MEAN * PRIOR_WEIGHT + weighted_quality) / denom,
        predicted_success_probability: (PRIOR_MEAN * PRIOR_WEIGHT + weighted_success) / denom,
        predicted_cost_cents: weighted_average(matches) { |m| m[:row].cost_cents },
        predicted_duration_seconds: weighted_average(matches) { |m| m[:row].duration_seconds },
        uncertainty: 1.0 / Math.sqrt(denom),
        sample_count: total_sim_weight.round(4),
        trained_at: trained_state.trained_at
      )
    end

    def weighted_average(matches)
      pairs = matches.filter_map do |match|
        value = yield(match)
        next if value.nil?

        [ value, match[:similarity] * match[:row].weight ]
      end
      return nil if pairs.empty?

      pairs.sum { |v, w| v * w } / pairs.sum { |_v, w| w }
    end

    def prior_prediction
      Prediction.new(
        predicted_objective_score: PRIOR_MEAN,
        predicted_quality_score: PRIOR_MEAN,
        predicted_success_probability: PRIOR_MEAN,
        predicted_cost_cents: nil,
        predicted_duration_seconds: nil,
        uncertainty: 1.0,
        sample_count: 0.0,
        trained_at: nil
      )
    end

    def goal_baseline_prediction(goal)
      goal_rows = trained_state.rows.select { |row| row.features.goal == goal }
      return prior_prediction_for_trained_state if goal_rows.empty?

      total_weight = goal_rows.sum(&:weight)

      Prediction.new(
        predicted_objective_score: weighted_mean(goal_rows.map(&:objective_score), goal_rows.map(&:weight), total_weight),
        predicted_quality_score: weighted_mean(goal_rows.map(&:quality_score), goal_rows.map(&:weight), total_weight),
        predicted_success_probability: weighted_mean(goal_rows.map { |row| row.success ? 1.0 : 0.0 }, goal_rows.map(&:weight), total_weight),
        predicted_cost_cents: nil,
        predicted_duration_seconds: nil,
        uncertainty: 1.0,
        sample_count: 0.0,
        trained_at: trained_state.trained_at
      )
    end

    def prior_prediction_for_trained_state
      prior_prediction.dup.tap do |prediction|
        prediction.trained_at = trained_state.trained_at
      end
    end

    def empty_trained_state
      TrainedState.new(
        rows: [],
        training_size: 0,
        trained_at: Time.current,
        global_mean_objective: nil,
        global_mean_quality: nil,
        global_success_rate: nil
      )
    end

    def weighted_mean(values, weights, total_weight = nil)
      total = total_weight || weights.sum
      return PRIOR_MEAN if total.zero?

      values.zip(weights).sum { |v, w| v * w } / total
    end
  end
end
