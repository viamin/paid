# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends one reasoned correction after unblinding. The original blinded
    # label and its frozen comparison remain immutable evidence; the separate
    # revised_* fields make the correction attributable without rescoring it.
    # @spec FACET-CONFIDENCE-021
    class ReviseLabel
      Result = Data.define(:success, :error, :label) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:, case_id:, judgment: nil)
        @evaluation = evaluation
        @actor = actor
        @case_id = case_id
        @judgment = judgment
      end

      def call
        @evaluation.with_lock { revise }
      end

      private

      attr_reader :evaluation, :actor, :case_id, :judgment

      def revise
        return failure("reference judgments must be frozen before recording a correction") unless evaluation.frozen?
        return failure("only the operator who started the evaluation may record corrections") unless actor&.id == evaluation.created_by_id

        label = evaluation.labels.find_by(case_id: case_id, state: "labeled")
        return failure("case #{case_id.inspect} has no frozen reference judgment to correct") unless label
        return failure("this judgment already has an immutable recorded correction") if label.revised?

        corpus_case = evaluation.corpus.find_case(case_id)
        return failure("case #{case_id.inspect} is not part of the frozen corpus") unless corpus_case
        return failure("the cited evidence must be one of #{evidence_references(corpus_case).join(', ')}") unless evidence_references(corpus_case).include?(cited_evidence_reference)

        label.assign_attributes(revision_attributes)
        return failure(label.errors.full_messages.to_sentence) unless label.save

        log_revision(label)
        Result.new(success: true, error: nil, label: label)
      end

      def revision_attributes
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

      def cited_evidence_reference
        judgment.fetch(:cited_evidence_reference).to_s.strip
      end

      def evidence_references(corpus_case)
        corpus_case.fetch("evidence").map { |item| item.fetch("reference") }
      end

      def log_revision(label)
        Rails.logger.info(
          message: "facet_confidence.reference_judgment_revised",
          project_id: evaluation.project_id,
          facet_confidence_evaluation_id: evaluation.id,
          case_id: case_id,
          actor_user_id: actor.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, label: nil)
      end
    end
  end
end
