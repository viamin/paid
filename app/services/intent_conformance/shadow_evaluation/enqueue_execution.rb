# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Enqueue-only admission to reviewer execution (#4642): re-validates the
    # same freeze/digest/identity gates the executor enforces, then claims
    # the evaluation as queued with a single conditional UPDATE so a
    # duplicate submission cannot double-enqueue. No reviewer call happens
    # here — the request returns promptly and the GoodJob job (guarded by
    # the executor's advisory lock) owns the lifecycle from here on.
    # @spec INTENT-CONFORMANCE-ROLLOUT-006
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class EnqueueExecution
      Result = Data.define(:success, :error, :evaluation, :already_active) do
        def success? = success
        def already_active? = already_active
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor: nil)
        @evaluation = evaluation
        @actor = actor
      end

      def call
        return failure("reviewer execution requires a frozen reference label set") unless @evaluation.answers_visible?
        return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless @evaluation.corpus.matches_recorded_digest?
        return failure("no corpus cases to evaluate") if @evaluation.corpus.case_ids.empty?
        identity_error = identity_error_for(@evaluation)
        return failure(identity_error) if identity_error

        return already_active(@evaluation.reload) if @evaluation.execution_active?
        return already_active(@evaluation.reload) unless claim_queued!

        ShadowEvaluationExecuteJob.perform_later(@evaluation.id)
        log_queued
        Result.new(success: true, error: nil, evaluation: @evaluation, already_active: false)
      end

      private

      attr_reader :evaluation, :actor

      # Atomic claim from any re-executable post-freeze state: two racing
      # submissions both validate, but only the winner's UPDATE matches and
      # only that request enqueues the job. The GoodJob concurrency key and
      # the executor's advisory lock remain the second and third dedup
      # layers. A new pass always clears a stale cancellation and reason.
      def claim_queued!
        now = Time.current
        IntentConformanceShadowEvaluation.where(id: @evaluation.id)
          .where(status: IntentConformanceShadowEvaluation::RE_EXECUTABLE_STATUSES)
          .update_all(
            status: "queued",
            execution_queued_at: now,
            cancel_requested_at: nil,
            last_failure_reason: nil,
            updated_at: now
          ).positive?
      end

      # The same pinned model/prompt identity gate ExecuteReviewer enforces,
      # checked here so an unexecutable manifest fails the request promptly
      # instead of failing the job after enqueue.
      def identity_error_for(evaluation)
        identity = evaluation.corpus.reviewer_identity
        return "corpus manifest reviewer model is required" if identity.fetch("model").blank?
        return "corpus manifest reviewer prompt version is not executable" unless identity.fetch("prompt_version") == ReviewerLlm::PROMPT_VERSION

        require "digest"
        return "corpus manifest reviewer prompt digest does not match the executable prompt" unless identity.fetch("prompt_sha256") == Digest::SHA256.hexdigest(ReviewerLlm::PROMPT)

        nil
      end

      def already_active(evaluation)
        Result.new(success: true, error: nil, evaluation: evaluation, already_active: true)
      end

      def log_queued
        Rails.logger.info(
          message: "intent_conformance.shadow_evaluation_execution_queued",
          project_id: @evaluation.project_id,
          shadow_evaluation_id: @evaluation.id,
          actor_user_id: actor&.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, evaluation: nil, already_active: false)
      end
    end
  end
end
