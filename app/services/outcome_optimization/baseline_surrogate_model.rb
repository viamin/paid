# frozen_string_literal: true

require "matrix"

module OutcomeOptimization
  class BaselineSurrogateModel
    Prediction = Data.define(:mean, :uncertainty, :observation_count, :training_sample_count)

    DEFAULT_MEAN = 0.5
    DEFAULT_UNCERTAINTY = 0.25
    MIN_UNCERTAINTY = 0.05
    RIDGE_PENALTY = 0.1

    def self.train(scope: BundleOutcome.for_training)
      new(dataset: TrainingDataset.call(scope:))
    end

    def initialize(dataset:)
      @dataset = dataset
      @feature_names = dataset.feature_names
      @bundle_observation_counts = dataset.rows.each_with_object(Hash.new(0)) do |row, counts|
        counts[row.configuration_bundle_id] += 1
      end
      @global_mean = dataset.empty? ? DEFAULT_MEAN : dataset.rows.sum(&:outcome_score) / dataset.sample_count.to_f
      @weights, @rmse = train_regression
    end

    def predict(bundle:, context_features:)
      features = FeatureExtractor.call(bundle:, context_features:)
      observation_count = bundle_observation_counts[bundle.id]
      mean = dataset.empty? ? global_mean : linear_prediction(features)

      Prediction.new(
        mean: clamp(mean),
        uncertainty: prediction_uncertainty(features:, observation_count:),
        observation_count:,
        training_sample_count: dataset.sample_count
      )
    end

    private

    attr_reader :dataset, :feature_names, :bundle_observation_counts, :global_mean, :weights, :rmse

    def train_regression
      return [ [], DEFAULT_UNCERTAINTY ] if dataset.empty?

      design_matrix = Matrix.rows(dataset.rows.map { |row| design_row(row.features) })
      target_vector = Vector.elements(dataset.rows.map(&:outcome_score))
      penalty = Matrix.build(design_matrix.column_count, design_matrix.column_count) do |row, column|
        row == column && row.positive? ? RIDGE_PENALTY : 0.0
      end

      coefficients = ((design_matrix.transpose * design_matrix) + penalty).inverse * design_matrix.transpose * target_vector
      residuals = design_matrix * coefficients - target_vector
      mse = residuals.to_a.sum { |value| value**2 } / dataset.sample_count.to_f

      [ coefficients.to_a, Math.sqrt(mse) ]
    rescue ExceptionForMatrix::ErrNotRegular
      [ [], DEFAULT_UNCERTAINTY ]
    end

    def design_row(features)
      [ 1.0 ] + feature_names.map { |feature_name| features.fetch(feature_name, 0.0) }
    end

    def linear_prediction(features)
      intercept, *feature_weights = weights
      prediction = intercept || global_mean

      feature_names.each_with_index do |feature_name, index|
        prediction += feature_weights[index].to_f * features.fetch(feature_name, 0.0)
      end

      prediction
    end

    def prediction_uncertainty(features:, observation_count:)
      feature_count = [ features.size, 1 ].max
      overlap = features.keys.intersection(feature_names).size
      coverage = overlap / feature_count.to_f
      sample_penalty = 1.0 / Math.sqrt(observation_count + 1)
      novelty_penalty = (1.0 - coverage) * 0.25
      base_uncertainty = [ rmse, DEFAULT_UNCERTAINTY ].max

      clamp(base_uncertainty + (sample_penalty * 0.15) + novelty_penalty, min: MIN_UNCERTAINTY)
    end

    def clamp(value, min: 0.0, max: 1.0)
      [ [ value, min ].max, max ].min.round(4)
    end
  end
end
