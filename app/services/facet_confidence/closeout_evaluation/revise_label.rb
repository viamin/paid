# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends a complete, reasoned post-unblinding correction without mutating
    # the blinded judgment or the report comparison derived from that judgment.
    # @spec FACET-CONFIDENCE-021
    class ReviseLabel
      Result = Data.define(:success, :error, :label) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:, case_id:, judgment:)
        @evaluation = evaluation
        @actor = actor
        @case_id = case_id
        @judgment = judgment
      end

      def call
        evaluation.with_lock { revise }
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      end

      private

      attr_reader :evaluation, :actor, :case_id, :judgment

      def revise
        return failure("corrections are available only after the reference set is frozen") unless evaluation.frozen?
        return failure("only the operator who started the evaluation is its sole reference judge") unless actor&.id == evaluation.created_by_id

        label = evaluation.labels.find_by(case_id: case_id, state: "labeled")
        return failure("case #{case_id.inspect} has no frozen reference judgment to correct") unless label
        return failure("this judgment already carries a recorded correction") if label.revised?
        return failure("the cited evidence must be one of #{evidence_references.join(', ')}") unless evidence_references.include?(cited_evidence_reference)

        label.update!(revised_attributes)
        log_revision(label)
        Result.new(success: true, error: nil, label: label)
      end

      def revised_attributes
        {
          revised_verdict: judgment.fetch(:verdict).presence,
          revised_intent_band: judgment.fetch(:intent_band).presence,
          revised_technical_band: judgment.fetch(:technical_band).presence,
          revised_readiness: judgment.fetch(:readiness).presence,
          revised_cited_evidence_reference: cited_evidence_reference,
          revised_reason: judgment.fetch(:reason).to_s.strip,
          revised_by: actor,
          revised_at: Time.current
        }
      end

      def corpus_case = evaluation.corpus.find_case(case_id)
      def evidence_references = corpus_case.to_h.fetch("evidence", []).map { |item| item.fetch("reference") }
      def cited_evidence_reference = judgment.fetch(:cited_evidence_reference).to_s.strip

      def log_revision(label)
        Rails.logger.info(message: "facet_confidence.reference_judgment_revised", project_id: evaluation.project_id,
          facet_confidence_evaluation_id: evaluation.id, case_id: label.case_id, actor_user_id: actor.id)
      end

      def failure(message) = Result.new(success: false, error: message, label: nil)
    end
  end
end
