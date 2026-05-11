# frozen_string_literal: true

module ConfigurationBundles
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
      @trained_state = trained_state
    end

    def self.train(dataset:)
      new.train(dataset:)
    end

    def self.call(bundle_definition:, trained_state:)
      new(trained_state:).predict(bundle_definition:)
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
          global_success_rate: rows.count(&:success).to_f / rows.size
        )
      end

      self
    end

    def predict(bundle_definition:)
      return prior_prediction unless trained_state&.rows&.any?

      query_features = FeatureExtractor.call(bundle_definition)
      matches = find_matches(query_features)

      return global_baseline_prediction if matches.empty?

      weighted_prediction(query_features, matches)
    end

    def trained?
      trained_state&.rows&.any? == true
    end

    private

    def find_matches(query_features)
      trained_state.rows.filter_map do |row|
        similarity = compute_similarity(query_features, row.features)
        next if similarity <= 0

        { row: row, similarity: similarity }
      end
    end

    def compute_similarity(query, historical)
      return 0.0 unless query.goal == historical.goal

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
      total_weight = matches.sum { |m| m[:similarity] * m[:row].weight }
      return nil if total_weight.zero?

      values = matches.filter_map { |m| yield(m).then { |v| v if v.to_i.positive? } }
      weights = matches.filter_map { |m| yield(m).then { |v| m[:similarity] * m[:row].weight if v.to_i.positive? } }
      return nil if weights.sum.zero?

      values.zip(weights).sum { |v, w| v * w } / weights.sum
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

    def global_baseline_prediction
      Prediction.new(
        predicted_objective_score: trained_state.global_mean_objective,
        predicted_quality_score: trained_state.global_mean_quality,
        predicted_success_probability: trained_state.global_success_rate,
        predicted_cost_cents: nil,
        predicted_duration_seconds: nil,
        uncertainty: 1.0,
        sample_count: 0.0,
        trained_at: trained_state.trained_at
      )
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
