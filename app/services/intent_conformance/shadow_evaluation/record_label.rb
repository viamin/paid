# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Records (or skips) one blinded reference label for the declared
    # maintainer. Only the declared maintainer may label, only while the
    # evaluation is in the labeling state, and only for a case inside the
    # frozen corpus. Saves are upserts, so save/resume is durable; a skipped
    # case stays skipped (never completed) until explicitly labeled.
    # @spec INTENT-CONFORMANCE-ROLLOUT-005
    class RecordLabel
      Result = Data.define(:success, :error, :label) do
        def success? = success
      end

      OUTCOMES = IntentConformance::ShadowEvaluationPolicy::LABELS

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor:, case_id:, outcome:, cited_design_claim: nil, reason: nil)
        @evaluation = evaluation
        @actor = actor
        @case_id = case_id
        @outcome = outcome
        @cited_design_claim = cited_design_claim
        @reason = reason
      end

      def call
        return failure("reference labels are frozen; post-result changes must use a recorded revision") unless @evaluation.labeling?
        return failure("only the declared solo maintainer may record reference labels") unless @actor&.id == @evaluation.solo_maintainer_id
        return failure("case #{@case_id.inspect} is not part of the frozen corpus") unless @evaluation.corpus.find_case(@case_id)
        return failure("outcome must be one of #{OUTCOMES.join(', ')}") unless skip? || OUTCOMES.include?(@outcome)
        return failure("a cited design claim is required") if recording_label? && @cited_design_claim.to_s.strip.empty?
        return failure("a reason is required") if recording_label? && @reason.to_s.strip.empty?

        persist(build_label(@evaluation.labels.find_or_initialize_by(case_id: @case_id)))
      rescue ActiveRecord::RecordNotUnique
        # A double-submit of the same case races find_or_initialize_by: both
        # requests build a new row and the loser's insert hits the unique
        # (shadow_evaluation_id, case_id) index. The winner's row is the
        # durable save/resume state, so the loser retries once as an in-place
        # update instead of surfacing the index race as a 500 (#4598 review).
        persist(build_label(@evaluation.labels.find_by!(case_id: @case_id)))
      end

      private

      attr_reader :evaluation, :actor, :case_id, :outcome, :cited_design_claim, :reason

      def persist(label)
        return failure(label.errors.full_messages.to_sentence) unless label.save

        log_recorded(label)
        Result.new(success: true, error: nil, label: label)
      end

      def build_label(label)
        if skip?
          label.state = "skipped"
          label.outcome = nil
          label.cited_design_claim = nil
          label.reason = nil
        else
          label.state = "labeled"
          label.outcome = @outcome
          label.cited_design_claim = @cited_design_claim.to_s.strip
          label.reason = @reason.to_s.strip
        end
        label.recorded_by = @actor
        label.recorded_at = Time.current
        label
      end

      def skip?
        outcome.nil?
      end

      def recording_label?
        !skip?
      end

      def log_recorded(label)
        Rails.logger.info(
          message: "intent_conformance.shadow_evaluation_label_recorded",
          project_id: @evaluation.project_id,
          shadow_evaluation_id: @evaluation.id,
          case_id: @case_id,
          state: label.state,
          actor_user_id: @actor.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, label: nil)
      end
    end
  end
end
