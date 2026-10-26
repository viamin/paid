# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends an auditable post-unblinding correction without changing the
    # frozen blinded label or the frozen-label divergence measures.
    # @spec FACET-CONFIDENCE-021
    class ReviseLabel
      Result = Data.define(:success, :error, :revision) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:, case_id:, judgment:, revision_reason:)
        @evaluation = evaluation
        @actor = actor
        @case_id = case_id
        @judgment = judgment
        @revision_reason = revision_reason
      end

      def call
        @evaluation.with_lock { revise }
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      end

      private

      attr_reader :evaluation, :actor, :case_id, :judgment, :revision_reason

      def revise
        return failure("reference judgments must be frozen before they can be corrected") unless @evaluation.frozen?
        return failure("only the operator who started the evaluation is its sole reference judge") unless @actor&.id == @evaluation.created_by_id

        corpus_case = @evaluation.corpus.find_case(@case_id)
        return failure("case #{@case_id.inspect} is not part of the frozen corpus") unless corpus_case
        return failure("the cited evidence must be one of #{evidence_references(corpus_case).join(', ')}") unless evidence_references(corpus_case).include?(cited_evidence_reference)

        label = @evaluation.labels.find_by(case_id: @case_id)
        return failure("the frozen reference judgment for case #{@case_id.inspect} is missing") unless label&.labeled?

        revision = label.revisions.create!(**revision_attributes)
        FacetConfidence::CloseoutEvaluation::CompileReport.call(evaluation: @evaluation)
        log_revision(revision)
        Result.new(success: true, error: nil, revision: revision)
      end

      def revision_attributes
        {
          verdict: judgment.fetch(:verdict).presence,
          intent_band: judgment.fetch(:intent_band).presence,
          technical_band: judgment.fetch(:technical_band).presence,
          readiness: judgment.fetch(:readiness).presence,
          cited_evidence_reference: cited_evidence_reference,
          reason: judgment.fetch(:reason).to_s.strip,
          revision_reason: revision_reason.to_s.strip,
          revised_by: actor,
          revised_at: Time.current
        }
      end

      def cited_evidence_reference = judgment.fetch(:cited_evidence_reference).to_s.strip
      def evidence_references(corpus_case) = corpus_case.fetch("evidence").map { |item| item.fetch("reference") }

      def log_revision(revision)
        Rails.logger.info(
          message: "facet_confidence.reference_judgment_revised",
          project_id: evaluation.project_id,
          facet_confidence_evaluation_id: evaluation.id,
          case_id: case_id,
          revision_id: revision.id,
          actor_user_id: actor.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, revision: nil)
      end
    end
  end
end
