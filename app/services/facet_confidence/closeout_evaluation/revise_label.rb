# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends one reasoned post-unblinding correction without overwriting the
    # blinded judgment or the measures compiled from it.
    # @spec FACET-CONFIDENCE-021
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
        return failure("corrections are recorded only after unblinding") unless evaluation.frozen?

        evaluation.with_lock { revise }
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      end

      private

      attr_reader :evaluation, :actor, :case_id, :revision

      def revise
        label = evaluation.labels.find_by(case_id: case_id, state: "labeled")
        return failure("case #{case_id.inspect} has no frozen reference judgment to correct") unless label
        return failure("this judgment already has a recorded correction") if label.revised?
        return failure("the cited evidence must be one of #{case_evidence_references.join(', ')}") unless case_evidence_references.include?(cited_evidence_reference)

        label.update!(revision_attributes)
        CompileReport.call(evaluation: evaluation)
        log_revision(label)
        Result.new(success: true, error: nil, label: label)
      end

      def revision_attributes
        revision.slice(:verdict, :intent_band, :technical_band, :readiness).transform_keys { |key| "revised_#{key}" }.merge(
          revised_cited_evidence_reference: cited_evidence_reference,
          revised_reason: revision.fetch(:reason).to_s.strip,
          revised_by: actor,
          revised_at: Time.current
        )
      end

      def cited_evidence_reference = revision.fetch(:cited_evidence_reference).to_s.strip
      def case_evidence_references = evaluation.corpus.find_case(case_id).fetch("evidence").map { |item| item.fetch("reference") }

      def log_revision(label)
        Rails.logger.info(message: "facet_confidence.reference_judgment_revised", project_id: evaluation.project_id,
          facet_confidence_evaluation_id: evaluation.id, case_id: case_id, actor_user_id: actor.id)
      end

      def failure(message) = Result.new(success: false, error: message, label: nil)
    end
  end
end
