# frozen_string_literal: true

module OutcomeOptimization
  class PredictBundlePerformance
    def self.call(...)
      new(...).call
    end

    def initialize(bundle:, context_features:, scope: BundleOutcome.for_training)
      @bundle = bundle
      @context_features = context_features
      @scope = scope
    end

    def call
      BaselineSurrogateModel.train(scope:).predict(bundle:, context_features:)
    end

    private

    attr_reader :bundle, :context_features, :scope
  end
end
