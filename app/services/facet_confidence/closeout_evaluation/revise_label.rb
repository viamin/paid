# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends a post-unblinding correction while preserving the original
    # blinded judgment and its frozen comparison.
    # @spec FACET-CONFIDENCE-022
    class ReviseLabel
      Result = Data.define(:success, :error, :revision) do
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
        evaluation.with_lock { append }
      rescue ActiveRecord::RecordNotUnique
        failure("this reference judgment already has a correction")
      end

      private

      attr_reader :evaluation, :actor, :case_id, :judgment

      def append
        return failure("reference judgments must be frozen before a correction") unless evaluation.frozen?
        return failure("only the operator who started the evaluation is its sole reference judge") unless actor&.id == evaluation.created_by_id

        label = evaluation.labels.find_by(case_id:, state: "labeled")
        return failure("case #{case_id.inspect} has no frozen reference judgment to correct") unless label
        return failure("this reference judgment already has a correction") if label.revision
        return failure("the cited evidence must be one of #{references_for(case_id).join(', ')}") unless references_for(case_id).include?(citation)

        revision = label.create_revision(revision_attributes)
        return failure(revision.errors.full_messages.to_sentence) unless revision.persisted?

        CompileReport.call(evaluation:)
        log_revision(label)
        Result.new(success: true, error: nil, revision:)
      end

      def revision_attributes
        judgment.slice(:verdict, :intent_band, :technical_band, :readiness).merge(
          cited_evidence_reference: citation, reason: judgment.fetch(:reason).to_s.strip,
          recorded_by: actor, recorded_at: Time.current)
      end

      def citation = judgment.fetch(:cited_evidence_reference).to_s.strip
      def references_for(id) = evaluation.corpus.find_case(id).fetch("evidence").map { |item| item.fetch("reference") }

      def log_revision(label)
        Rails.logger.info(message: "facet_confidence.reference_judgment_revised", project_id: evaluation.project_id,
          facet_confidence_evaluation_id: evaluation.id, case_id: label.case_id, actor_user_id: actor.id)
      end

      def failure(message) = Result.new(success: false, error: message, revision: nil)
    end
  end
end
