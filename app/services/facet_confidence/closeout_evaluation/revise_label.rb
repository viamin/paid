# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends a reasoned post-unblinding correction without ever changing the
    # original blinded judgment or the report measures derived from it.
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
        result = evaluation.with_lock { revise }
        log_revision(result.label) if result.success?
        result
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      end

      private

      attr_reader :evaluation, :actor, :case_id, :judgment

      def revise
        return failure("reference judgments must be frozen before a correction can be recorded") unless evaluation.frozen?
        return failure("only the operator who started the evaluation is its sole reference judge") unless actor&.id == evaluation.created_by_id

        label = evaluation.labels.find_by(case_id:, state: "labeled")
        return failure("case #{case_id.inspect} has no frozen reference judgment to correct") unless label
        return failure("this judgment already carries a recorded correction") if label.revised?
        return failure("the cited evidence must be one of #{case_evidence_references.join(', ')}") unless case_evidence_references.include?(citation)

        label.update!(revision_attributes)
        CompileReport.call(evaluation:)
        Result.new(success: true, error: nil, label: label)
      end

      def revision_attributes
        {
          revised_verdict: judgment.fetch(:verdict).presence,
          revised_intent_band: judgment.fetch(:intent_band).presence,
          revised_technical_band: judgment.fetch(:technical_band).presence,
          revised_readiness: judgment.fetch(:readiness).presence,
          revised_cited_evidence_reference: citation,
          revised_reason: judgment.fetch(:reason).to_s.strip,
          revised_by: actor,
          revised_at: Time.current
        }
      end

      def citation = judgment.fetch(:cited_evidence_reference).to_s.strip
      def case_evidence_references = evaluation.corpus.find_case(case_id).fetch("evidence").map { |item| item.fetch("reference") }

      def log_revision(label)
        Rails.logger.info(message: "facet_confidence.reference_judgment_revised", project_id: evaluation.project_id,
          facet_confidence_evaluation_id: evaluation.id, case_id:, actor_user_id: actor.id)
      end

      def failure(message) = Result.new(success: false, error: message, label: nil)
    end
  end
end
