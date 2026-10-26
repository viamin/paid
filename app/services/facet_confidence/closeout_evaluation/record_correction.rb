# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends one reasoned correction after unblinding. The original frozen
    # label and compiled report are never recomputed or overwritten.
    # @spec FACET-CONFIDENCE-021
    class RecordCorrection
      Result = Data.define(:success, :error, :label) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:, case_id:, correction:)
        @evaluation = evaluation
        @actor = actor
        @case_id = case_id
        @correction = correction
      end

      def call
        @evaluation.with_lock { record }
      end

      private

      attr_reader :evaluation, :actor, :case_id, :correction

      def record
        return failure("corrections are recorded only after the reference set is frozen") unless evaluation.frozen?
        return failure("only the operator who started the evaluation is its sole reference judge") unless actor&.id == evaluation.created_by_id

        label = evaluation.labels.find_by(case_id: case_id, state: "labeled")
        return failure("case #{case_id.inspect} has no frozen reference judgment to correct") unless label
        return failure("this judgment already carries a recorded correction") if label.revised?

        corpus_case = evaluation.corpus.find_case(case_id)
        return failure("case #{case_id.inspect} is not part of the frozen corpus") unless corpus_case
        return failure("the cited evidence must be one of #{evidence_references(corpus_case).join(', ')}") unless evidence_references(corpus_case).include?(cited_evidence_reference)

        persist(label)
      end

      def persist(label)
        label.assign_attributes(revision_attributes)
        return failure(label.errors.full_messages.to_sentence) unless label.save

        log_correction(label)
        Result.new(success: true, error: nil, label: label)
      end

      def revision_attributes
        {
          revised_verdict: correction.fetch(:verdict).presence,
          revised_intent_band: correction.fetch(:intent_band).presence,
          revised_technical_band: correction.fetch(:technical_band).presence,
          revised_readiness: correction.fetch(:readiness).presence,
          revised_cited_evidence_reference: cited_evidence_reference,
          revised_reason: correction.fetch(:reason).to_s.strip,
          revised_by: actor,
          revised_at: Time.current
        }
      end

      def cited_evidence_reference = correction.fetch(:cited_evidence_reference).to_s.strip

      def evidence_references(corpus_case)
        corpus_case.fetch("evidence").map { |item| item.fetch("reference") }
      end

      def log_correction(label)
        Rails.logger.info(
          message: "facet_confidence.reference_judgment_corrected",
          project_id: evaluation.project_id,
          facet_confidence_evaluation_id: evaluation.id,
          case_id: label.case_id,
          actor_user_id: actor.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, label: nil)
      end
    end
  end
end
