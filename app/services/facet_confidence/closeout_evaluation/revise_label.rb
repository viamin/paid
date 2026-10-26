# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends one reasoned, post-unblinding correction without mutating the
    # blinded label or the measures compiled from it. Only the authenticated
    # reference judge can record it after the reference set is frozen.
    # @spec FACET-CONFIDENCE-021
    class ReviseLabel
      Result = Data.define(:success, :error, :label) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:, case_id:, judgment:, reason:)
        @evaluation = evaluation
        @actor = actor
        @case_id = case_id
        @judgment = judgment
        @reason = reason
      end

      def call
        @evaluation.with_lock { revise }
      end

      private

      attr_reader :evaluation, :actor, :case_id, :judgment, :reason

      def revise
        return failure("reference judgments must be frozen before they can be corrected") unless evaluation.frozen?
        return failure("only the operator who started the evaluation is its sole reference judge") unless actor&.id == evaluation.created_by_id

        label = evaluation.labels.find_by(case_id: case_id, state: "labeled")
        return failure("case #{case_id.inspect} has no frozen reference judgment to revise") unless label
        return failure("this judgment already carries a recorded revision") if label.revised?
        return failure("a reason for the correction is required") if reason.to_s.strip.empty?

        corpus_case = evaluation.corpus.find_case(case_id)
        return failure("case #{case_id.inspect} is not part of the frozen corpus") unless corpus_case
        return failure("the cited evidence must be one of #{evidence_references(corpus_case).join(', ')}") unless evidence_references(corpus_case).include?(citation)

        label.assign_attributes(revised_attributes)
        return failure(label.errors.full_messages.to_sentence) unless label.save

        CompileReport.call(evaluation: evaluation)

        log_revision(label)
        Result.new(success: true, error: nil, label: label)
      end

      def revised_attributes
        {
          revised_verdict: judgment.fetch(:verdict).presence,
          revised_intent_band: judgment.fetch(:intent_band).presence,
          revised_technical_band: judgment.fetch(:technical_band).presence,
          revised_readiness: judgment.fetch(:readiness).presence,
          revised_cited_evidence_reference: citation,
          revised_judgment_reason: judgment.fetch(:reason).to_s.strip,
          revised_reason: reason.to_s.strip,
          revised_by: actor,
          revised_at: Time.current
        }
      end

      def citation = judgment.fetch(:cited_evidence_reference).to_s.strip
      def evidence_references(corpus_case) = corpus_case.fetch("evidence").map { |item| item.fetch("reference") }

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
