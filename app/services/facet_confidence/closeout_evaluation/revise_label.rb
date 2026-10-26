# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends a reasoned post-unblinding correction without altering frozen evidence.
    # @spec FACET-CONFIDENCE-021
    class ReviseLabel
      Result = Data.define(:success, :error, :revision) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:, case_id:, judgment:)
        @evaluation, @actor, @case_id, @judgment = evaluation, actor, case_id, judgment
      end

      def call
        return failure("only the operator who started the evaluation is its sole reference judge") unless actor&.id == evaluation.created_by_id
        return failure("reference judgments must be frozen before a correction is recorded") unless evaluation.frozen?

        label = evaluation.labels.find_by(case_id:, state: "labeled")
        return failure("case #{case_id.inspect} has no frozen reference judgment to correct") unless label
        return failure("the cited evidence must be part of the frozen case") unless evaluation.corpus.find_case(case_id).fetch("evidence").any? { |item| item.fetch("reference") == citation }

        revision = label.revisions.create(attributes)
        return failure(revision.errors.full_messages.to_sentence) unless revision.persisted?

        Result.new(success: true, error: nil, revision:)
      end

      private

      attr_reader :evaluation, :actor, :case_id, :judgment

      def attributes
        judgment.slice(:verdict, :intent_band, :technical_band, :readiness).merge(cited_evidence_reference: citation,
          reason: judgment.fetch(:reason).to_s.strip, recorded_by: actor, recorded_at: Time.current)
      end

      def citation = judgment.fetch(:cited_evidence_reference).to_s.strip
      def failure(message) = Result.new(success: false, error: message, revision: nil)
    end
  end
end
