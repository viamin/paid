# frozen_string_literal: true

module ConfigurationBundles
  class TrainingDataset
    Row = Struct.new(
      :features,
      :quality_score,
      :objective_score,
      :success,
      :cost_cents,
      :duration_seconds,
      :tokens_used,
      :weight,
      keyword_init: true
    )

    Dataset = Struct.new(
      :rows,
      :feature_names,
      :size,
      keyword_init: true
    )

    MAX_ROWS = 500
    RECENCY_DECAY_HALF_LIFE_SECONDS = 30.days.to_i

    attr_reader :scope

    def initialize(scope:)
      @scope = scope
    end

    def self.call(...)
      new(...).build
    end

    def build
      rows = []
      feature_names = Set.new

      scope.order(created_at: :desc).limit(MAX_ROWS).each do |outcome|
        definition = outcome.configuration_bundle&.definition
        next unless definition.is_a?(Hash)

        features = FeatureExtractor.call(definition)
        objective_score = extract_objective_score(outcome)

        features.experiment_features.each_key { |key| feature_names.add(key) }

        rows << Row.new(
          features: features,
          quality_score: outcome.quality_score.to_f,
          objective_score: objective_score,
          success: outcome.success,
          cost_cents: outcome.cost_cents.to_i,
          duration_seconds: outcome.duration_seconds.to_i,
          tokens_used: outcome.tokens_used.to_i,
          weight: recency_weight(outcome)
        )
      end

      Dataset.new(rows: rows, feature_names: feature_names.to_a.sort, size: rows.size)
    end

    private

    def recency_weight(outcome)
      return 1.0 if outcome.created_at.nil?

      age = Time.current - outcome.created_at
      Math.exp(-Math.log(2) * age / RECENCY_DECAY_HALF_LIFE_SECONDS)
    end

    def extract_objective_score(outcome)
      stored = outcome.metrics&.fetch("objective_score", nil)
      return stored.to_f if stored.present?

      ConfigurationBundles::ObjectiveScore.call(
        project: outcome.agent_run.project,
        quality_score: outcome.quality_score,
        cost_cents: outcome.cost_cents,
        duration_seconds: outcome.duration_seconds
      ).objective_score
    end
  end
end
