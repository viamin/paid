# frozen_string_literal: true

module FeatureIntents
  # Converts an explicit chat correction into attributable evidence and starts
  # a new revision. Merely viewing an assessment cannot invoke this service.
  # @spec FACET-CONFIDENCE-003 FACET-CONFIDENCE-005
  class ChallengeFacetAssessment
    Result = Data.define(:evidence, :assessment)

    def self.call(...) = new(...).call

    def initialize(facet:, actor:, statement:, source_reference:, supersedes: nil)
      @facet = facet
      @actor = actor
      @statement = statement
      @source_reference = source_reference
      @supersedes = supersedes
    end

    def call
      facet.with_lock do
        validate_actor!
        validate_superseded_evidence!
        evidence = IngestFacetEvidence.call(facet:, attributes: evidence_attributes)
        supersedes&.update!(superseded_by: evidence)
        assessment = default_direction.assessments.where(status: "pending").order(created_at: :desc).first!
        Result.new(evidence:, assessment:)
      end
    end

    private

    attr_reader :actor, :facet, :source_reference, :statement, :supersedes

    def evidence_attributes
      { idempotency_key: "facet-challenge:#{source_reference}", source_type: "human_correction",
        source_reference:, statement:, occurred_at: Time.current, actor: }
    end

    def default_direction
      facet.directions.find_by!(status: "active")
    end

    def validate_actor!
      raise ActiveRecord::RecordInvalid, actor unless actor.account_id == facet.account_id
    end

    def validate_superseded_evidence!
      return if supersedes.nil? || (supersedes.account_id == facet.account_id && supersedes.feature_intent_facet_id == facet.id)

      raise ActiveRecord::RecordInvalid, supersedes
    end
  end
end
