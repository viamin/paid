# frozen_string_literal: true

module FeatureIntents
  # Captures the exact evidence revision before asynchronous assessment starts.
  # @spec FACET-CONFIDENCE-002 FACET-CONFIDENCE-012 FACET-CONFIDENCE-014
  class ScheduleFacetAssessment
    def self.call(...) = new(...).call

    def initialize(direction:)
      @direction = direction
    end

    def call
      direction.with_lock do
        assessment = direction.assessments.create!(account: direction.account,
          evidence_revision: facet.evidence_revision, status: "pending",
          rubric_version: AssessFacet::RUBRIC_VERSION, model_version: AssessFacet::MODEL_VERSION)
        AssessFacetJob.perform_later(assessment.id)
        assessment
      end
    end

    private

    attr_reader :direction
    def facet = direction.feature_intent_facet
  end
end
