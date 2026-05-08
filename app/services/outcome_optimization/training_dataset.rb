# frozen_string_literal: true

module OutcomeOptimization
  class TrainingDataset
    Row = Data.define(
      :bundle_outcome_id,
      :configuration_bundle_id,
      :agent_run_id,
      :project_id,
      :outcome_score,
      :component_scores,
      :context_features,
      :features
    )

    Dataset = Data.define(:rows, :feature_names) do
      def empty?
        rows.empty?
      end

      def sample_count
        rows.size
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(scope: BundleOutcome.for_training)
      @scope = scope
    end

    def call
      rows = scope.map { |bundle_outcome| build_row(bundle_outcome) }
      Dataset.new(rows:, feature_names: rows.flat_map { |row| row.features.keys }.uniq.sort)
    end

    private

    attr_reader :scope

    def build_row(bundle_outcome)
      Row.new(
        bundle_outcome_id: bundle_outcome.id,
        configuration_bundle_id: bundle_outcome.configuration_bundle_id,
        agent_run_id: bundle_outcome.agent_run_id,
        project_id: bundle_outcome.project_id,
        outcome_score: bundle_outcome.outcome_score.to_f,
        component_scores: bundle_outcome.component_scores,
        context_features: bundle_outcome.context_features,
        features: FeatureExtractor.call(
          bundle: bundle_outcome.configuration_bundle,
          context_features: bundle_outcome.context_features
        )
      )
    end
  end
end
