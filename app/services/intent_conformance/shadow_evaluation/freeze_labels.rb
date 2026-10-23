# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # The explicit finish action: freezes the reference label set. Refuses
    # while any case is unlabeled or skipped (skips are never silently
    # counted as completed), validates the whole set through the shared
    # policy module (the same validation the CLI ledger applies), and stamps
    # the freeze. Answers become visible only from here on.
    # @spec INTENT-CONFORMANCE-ROLLOUT-005
    # @spec INTENT-CONFORMANCE-ROLLOUT-006
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
        return failure("reference labels are already frozen") unless @evaluation.labeling?
        return failure("only the declared solo maintainer may freeze the reference set") unless @actor&.id == @evaluation.solo_maintainer_id

        cases = @evaluation.corpus.cases
        ShadowEvaluationPolicy.validate_reference_labels!(cases: cases, labels: serialized_labels, declaration: declaration)

        @evaluation.update!(status: "frozen", labels_frozen_at: Time.current)
        log_frozen
        Result.new(success: true, error: nil, evaluation: @evaluation)
      rescue ShadowEvaluationLedger::PendingHumanInput, ShadowEvaluationLedger::InvalidLedger => error
        failure(error.message)
      end

      private

      attr_reader :evaluation, :actor

      def declaration
        maintainer = evaluation.solo_maintainer
        ShadowEvaluationPolicy::Declaration.new(policy: "solo", maintainer: maintainer.email, recorded_at: evaluation.created_at)
      end

      def serialized_labels
        evaluation.labels.map do |label|
          {
            "case_id" => label.case_id,
            "state" => label.state,
            "verdict" => label.outcome,
            "operator" => label.recorded_by.email,
            "cited_design_claim" => label.cited_design_claim,
            "reason" => label.reason
          }
        end
      end

      def log_frozen
        Rails.logger.info(
          message: "intent_conformance.shadow_evaluation_labels_frozen",
          project_id: evaluation.project_id,
          shadow_evaluation_id: evaluation.id,
          case_count: evaluation.labels.where(state: "labeled").count,
          actor_user_id: actor.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, evaluation: nil)
      end
    end
  end
end
