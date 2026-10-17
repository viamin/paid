# frozen_string_literal: true

module FeatureIntents
  # Idempotently records one attributable source statement and advances the
  # facet revision only for newly accepted evidence.
  # @spec FACET-CONFIDENCE-002
  class IngestFacetEvidence
    class IdempotencyConflict < StandardError; end

    def self.call(...) = new(...).call

    def initialize(facet:, attributes:)
      @facet = facet
      @attributes = attributes.symbolize_keys
    end

    def call
      existing = FeatureIntentFacetEvidence.find_by(account: facet.account, idempotency_key: attributes.fetch(:idempotency_key))
      return find_existing! if existing

      facet.with_lock { create_or_return_existing }
    rescue ActiveRecord::RecordNotUnique
      find_existing!
    end

    private

    attr_reader :attributes, :facet

    def create_or_return_existing
      return find_existing! if existing_evidence

      evidence = facet.evidence.create!(attributes.merge(account: facet.account, evidence_revision: next_revision))
      facet.update!(evidence_revision: evidence.evidence_revision)
      evidence
    end

    def existing_evidence
      FeatureIntentFacetEvidence.find_by(account: facet.account, idempotency_key: attributes.fetch(:idempotency_key))
    end

    def find_existing!
      evidence = existing_evidence
      raise IdempotencyConflict, "evidence key belongs to another facet" if evidence && evidence.feature_intent_facet_id != facet.id

      evidence || raise(ActiveRecord::RecordNotFound)
    end

    def next_revision = facet.evidence_revision + 1
  end
end
