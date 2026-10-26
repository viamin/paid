# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends one post-unblinding correction without mutating the frozen
    # judgment or its report measures.
    # @spec FACET-CONFIDENCE-022
    class ReviseLabel
      Result = Data.define(:success, :error, :label) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:, case_id:, revision:)
        @evaluation = evaluation
        @actor = actor
        @case_id = case_id
        @revision = revision
      end

      def call
        return failure("only the operator who started the evaluation is its sole reference judge") unless actor&.id == evaluation.created_by_id
        return failure("corrections are recorded only after the reference set is frozen") unless evaluation.frozen?
        return failure("a complete corrected judgment is required") unless complete_revision?

        evaluation.with_lock { append_revision }
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      end

      private

      attr_reader :evaluation, :actor, :case_id, :revision

      def append_revision
        label = evaluation.labels.find_by(case_id:, state: "labeled")
        return failure("case #{case_id.inspect} has no frozen reference judgment to correct") unless label
        return failure("this judgment already carries a recorded correction") if label.revised?
        return failure("the cited evidence must be one of #{evidence_references.join(', ')}") unless evidence_references.include?(cited_evidence_reference)

        label.update!(revision_attributes)
        CompileReport.call(evaluation:)
        log_revision(label)
        Result.new(success: true, error: nil, label:)
      end

      def revision_attributes
        {
          revised_verdict: revision.fetch(:verdict).presence,
          revised_intent_band: revision.fetch(:intent_band).presence,
          revised_technical_band: revision.fetch(:technical_band).presence,
          revised_readiness: revision.fetch(:readiness).presence,
          revised_cited_evidence_reference: cited_evidence_reference,
          revised_reason: revision.fetch(:reason).to_s.strip,
          revised_by: actor,
          revised_at: Time.current
        }
      end

      def complete_revision?
        revision.is_a?(Hash) && %i[verdict intent_band technical_band readiness cited_evidence_reference reason].all? do |field|
          revision[field].present?
        end
      end

      def cited_evidence_reference = revision.fetch(:cited_evidence_reference).to_s.strip
      def evidence_references
        evaluation.corpus.find_case(case_id).fetch("evidence").map { |item| item.fetch("reference") }
      end

      def log_revision(label)
        Rails.logger.info(message: "facet_confidence.reference_judgment_revised", project_id: evaluation.project_id,
          facet_confidence_evaluation_id: evaluation.id, case_id:, actor_user_id: actor.id)
      end

      def failure(message) = Result.new(success: false, error: message, label: nil)
    end
  end
end
