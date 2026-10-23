# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Appends a reasoned post-result revision to a reference label after the
    # case's reviewer run exists. The original blinded label and every score
    # derived from it are preserved: the revision lands in revised_* fields
    # and the report lists it separately, never rescored.
    # @spec INTENT-CONFORMANCE-ROLLOUT-008
    class ReviseLabel
      Result = Data.define(:success, :error, :label) do
        def success? = success
      end

      OUTCOMES = IntentConformance::ShadowEvaluationPolicy::LABELS

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:, case_id:, revised_outcome:, reason:)
        @evaluation = evaluation
        @actor = actor
        @case_id = case_id
        @revised_outcome = revised_outcome
        @reason = reason
      end

      def call
        return failure("only the declared solo maintainer may record revisions") unless @actor&.id == @evaluation.solo_maintainer_id

        label = @evaluation.labels.find_by(case_id: @case_id, state: "labeled")
        return failure("case #{@case_id.inspect} has no frozen reference label to revise") unless label
        return failure("revisions are recorded only after the case's reviewer output exists") unless @evaluation.runs.exists?(case_id: @case_id)
        return failure("outcome must be one of #{OUTCOMES.join(', ')}") unless OUTCOMES.include?(@revised_outcome)
        return failure("a reason is required") if @reason.to_s.strip.empty?
        return failure("this label already carries a recorded revision") if label.revised?

        label.update!(
          revised_outcome: @revised_outcome,
          revised_reason: @reason.to_s.strip,
          revised_by: @actor,
          revised_at: Time.current
        )
        log_revision(label)
        Result.new(success: true, error: nil, label: label)
      end

      private

      attr_reader :evaluation, :actor, :case_id, :revised_outcome, :reason

      def log_revision(label)
        Rails.logger.info(
          message: "intent_conformance.shadow_evaluation_label_revised",
          project_id: @evaluation.project_id,
          shadow_evaluation_id: @evaluation.id,
          case_id: @case_id,
          original_outcome: label.outcome,
          revised_outcome: label.revised_outcome,
          actor_user_id: @actor.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, label: nil)
      end
    end
  end
end
