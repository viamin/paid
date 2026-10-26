# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Appends a post-unblinding correction without altering the frozen label or
    # report. @spec FACET-CONFIDENCE-022
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
        @evaluation.with_lock { revise }
      end

      private

      attr_reader :evaluation, :actor, :case_id, :judgment

      def revise
        return failure("reference judgments must be frozen before corrections can be recorded") unless evaluation.frozen?
        return failure("only the operator who started the evaluation is its sole reference judge") unless actor&.id == evaluation.created_by_id

        label = evaluation.labels.find_by(case_id: case_id, state: "labeled")
        return failure("case #{case_id.inspect} has no frozen reference judgment to correct") unless label
        return failure("the cited evidence must be one of #{evidence_references.join(', ')}") unless evidence_references.include?(citation)

        revision = evaluation.label_revisions.create(revision_attributes(label))
        return failure(revision.errors.full_messages.to_sentence) unless revision.persisted?

        log_revision(label, revision)
        Result.new(success: true, error: nil, revision: revision)
      end

      def revision_attributes(label)
        judgment.slice(:verdict, :intent_band, :technical_band, :readiness).merge(
          facet_confidence_evaluation_label: label, cited_evidence_reference: citation,
          reason: judgment.fetch(:reason).to_s.strip, recorded_by: actor, recorded_at: Time.current)
      end

      def evidence_references
        evaluation.corpus.find_case(case_id).fetch("evidence").map { |item| item.fetch("reference") }
      end

      def citation = judgment.fetch(:cited_evidence_reference).to_s.strip

      def log_revision(label, revision)
        Rails.logger.info(message: "facet_confidence.reference_judgment_revised", project_id: evaluation.project_id,
          facet_confidence_evaluation_id: evaluation.id, facet_confidence_evaluation_label_id: label.id,
          facet_confidence_evaluation_label_revision_id: revision.id, case_id: case_id, actor_user_id: actor.id)
      end

      def failure(message) = Result.new(success: false, error: message, revision: nil)
    end
  end
end
