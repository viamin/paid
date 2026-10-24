# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # The explicit finish action: freezes the reference-judgment set. Refuses
    # while any case is unlabeled or skipped (skips are never silently counted
    # as completed), re-checks the frozen corpus digest, and compiles the
    # reproducible report in the same transaction so a frozen evaluation
    # always carries its report. Frozen expectations become visible only from
    # here on.
    # @spec FACET-CONFIDENCE-021
    class FreezeLabels
      Result = Data.define(:success, :error, :evaluation) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:)
        @evaluation = evaluation
        @actor = actor
      end

      def call
        return failure("reference judgments are already frozen") unless @evaluation.labeling?
        return failure("only the operator who started the evaluation is its sole reference judge") unless @actor&.id == @evaluation.created_by_id
        return failure("corpus manifest changed since the evaluation was created — start a new evaluation") unless @evaluation.corpus.matches_recorded_digest?

        case_ids = @evaluation.corpus.case_ids
        done_ids = @evaluation.labels.where(state: %w[labeled skipped]).pluck(:case_id)
        unlabeled = case_ids.count - done_ids.length
        skipped = @evaluation.labels.where(state: "skipped").count
        if unlabeled.positive? || skipped.positive?
          return failure("every corpus case needs a labeled reference judgment before freezing (#{unlabeled} unlabeled, #{skipped} skipped)")
        end

        ActiveRecord::Base.transaction do
          @evaluation.update!(status: "frozen", labels_frozen_at: Time.current)
          CompileReport.call(evaluation: @evaluation)
        end
        log_frozen
        Result.new(success: true, error: nil, evaluation: @evaluation)
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      end

      private

      attr_reader :evaluation, :actor

      def log_frozen
        Rails.logger.info(
          message: "facet_confidence.reference_judgments_frozen",
          project_id: @evaluation.project_id,
          facet_confidence_evaluation_id: @evaluation.id,
          issue_id: @evaluation.issue_id,
          case_count: @evaluation.labels.where(state: "labeled").count,
          actor_user_id: @actor.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, evaluation: nil)
      end
    end
  end
end
