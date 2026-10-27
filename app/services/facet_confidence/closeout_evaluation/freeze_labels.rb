# frozen_string_literal: true

module FacetConfidence
  module CloseoutEvaluation
    # The explicit finish action: freezes the reference-judgment set. Refuses
    # while any case is unlabeled or skipped (skips are never silently counted
    # as completed), re-checks the frozen corpus digest, and compiles the
    # reproducible report in the same transaction so a frozen evaluation
    # always carries its report. The recheck and the freeze itself run under
    # the evaluation's row lock — the same row RecordLabel locks before
    # persisting a judgment — so the report is compiled from exactly the
    # committed label set, exactly once. Frozen expectations become visible
    # only from here on.
    # @spec FACET-CONFIDENCE-021 @spec FACET-CONFIDENCE-022
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

        # with_lock commits when the block ends, so the row lock is held for
        # the recheck, the freeze, and the report compile; only a committed
        # freeze reaches the completion log.
        result = @evaluation.with_lock { freeze }
        log_frozen if result.success?
        result
      rescue ActiveRecord::RecordInvalid => error
        failure(error.record.errors.full_messages.to_sentence)
      end

      private

      attr_reader :evaluation, :actor

      # Runs entirely inside the row-lock transaction opened by call: the
      # locked reload refreshes the lifecycle status and label state, so a
      # judgment save, a skip, or a rival freeze that committed after this
      # request read the evaluation is seen here — the set the report is
      # compiled from is exactly the committed label state, frozen once.
      def freeze
        return failure("reference judgments are already frozen") unless @evaluation.labeling?

        unlabeled, skipped = outstanding_counts
        if unlabeled.positive? || skipped.positive?
          return failure("every corpus case needs a labeled reference judgment before freezing (#{unlabeled} unlabeled, #{skipped} skipped)")
        end

        @evaluation.update!(status: "frozen", labels_frozen_at: Time.current)
        CompileReport.call(evaluation: @evaluation)
        resolve_evaluation_prerequisite
        Result.new(success: true, error: nil, evaluation: @evaluation)
      end

      def outstanding_counts
        done_ids = @evaluation.labels.where(state: %w[labeled skipped]).pluck(:case_id)
        unlabeled = @evaluation.corpus.case_ids.count - done_ids.length
        skipped = @evaluation.labels.where(state: "skipped").count
        [ unlabeled, skipped ]
      end

      def resolve_evaluation_prerequisite
        Notification.active.where(subject: @evaluation.issue,
          source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE).find_each do |notification|
          next unless notification.metadata["workflow"] == Inbox::ActionRequiredGuidance::FACET_CONFIDENCE_CLOSEOUT_EVALUATION

          Notifications::Resolve.call(account: notification.account, source: notification.source, subject: notification.subject, user: notification.user)
        end
      end

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
