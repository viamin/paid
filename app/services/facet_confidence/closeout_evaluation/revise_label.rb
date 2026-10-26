# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # Preserves the frozen blinded judgment and appends one reasoned post-unblinding
    # correction. The compiled comparison remains based on the original label.
    # @spec FACET-CONFIDENCE-022
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
        return failure("only the operator who started the evaluation may record a correction") unless actor&.id == evaluation.created_by_id
        return failure("corrections are available only after the reference set is frozen") unless evaluation.frozen?

        label = evaluation.labels.find_by(case_id:, state: "labeled")
        return failure("case #{case_id.inspect} has no frozen reference judgment to correct") unless label
        return failure("this judgment already has a recorded correction") if label.revised?
        return failure("the cited evidence must be from the frozen corpus case") unless citation_is_valid?

        label.assign_attributes(revision_attributes)
        return failure(label.errors.full_messages.to_sentence) unless label.save

        Rails.logger.info(message: "facet_confidence.reference_judgment_revised", project_id: evaluation.project_id,
          facet_confidence_evaluation_id: evaluation.id, case_id:, actor_user_id: actor.id)
        Result.new(success: true, error: nil, label:)
      end

      private

      attr_reader :evaluation, :actor, :case_id, :judgment

      def revision_attributes
        judgment.slice(:verdict, :intent_band, :technical_band, :readiness, :cited_evidence_reference)
          .transform_keys { |key| "revised_#{key}" }
          .merge(revised_reason: judgment.fetch(:reason).to_s.strip, revised_by: actor, revised_at: Time.current)
      end

      def citation_is_valid?
        evaluation.corpus.find_case(case_id)&.fetch("evidence")&.map { |item| item.fetch("reference") }
          &.include?(judgment.fetch(:cited_evidence_reference).to_s.strip)
      end

      def failure(error) = Result.new(success: false, error:, label: nil)
    end
  end
end
