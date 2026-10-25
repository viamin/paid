# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Enqueue side of the asynchronous execution lifecycle (#4642): the
    # originating request (UI action or documented command) only authorizes
    # and enqueues an idempotent background job and returns promptly — it
    # never runs the reviewer inline. The same freeze-before-execution,
    # pinned-identity, digest, and deduplication semantics as the executor
    # are validated before anything is queued, so prerequisite failures are
    # answered in the HTTP response rather than after the request returns.
    # A stale execution (killed worker, lost lock, or lost queued job) may
    # be resumed by a fresh enqueue; a live one refuses duplicates.
    # @spec INTENT-CONFORMANCE-ROLLOUT-006
    # @spec INTENT-CONFORMANCE-ROLLOUT-007
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class EnqueueExecution
      Result = Data.define(:success, :error, :evaluation, :resumed) do
        def success? = success
      end

      # A queued job should start within minutes; an execution whose
      # heartbeat is older than this is stranded (dead worker or lost job),
      # never "in progress". Individual provider calls are additionally
      # guarded by the advisory-lock probe, so a merely slow case is never
      # mistaken for a dead worker. Comfortably above the recovery sweep's
      # cadence so normal queue latency never consumes resume budget.
      STALE_EXECUTION_AFTER = 30.minutes

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor: nil)
        @evaluation = evaluation
        @actor = actor
      end

      def call
        return failure("reviewer execution requires a frozen reference label set") unless @evaluation.answers_visible?
        return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless @evaluation.corpus.matches_recorded_digest?
        return failure("no corpus cases to evaluate") if @evaluation.corpus.case_ids.empty?
        identity_error = ExecuteReviewer.identity_error(@evaluation)
        return failure(identity_error) if identity_error

        active_error = active_execution_error
        return failure(active_error) if active_error

        resumed = @evaluation.execution_pending?
        enlist!
        Result.new(success: true, error: nil, evaluation: @evaluation.reload, resumed: resumed)
      rescue ShadowEvaluationCorpus::MissingManifest => error
        failure(error.message)
      end

      private

      attr_reader :evaluation, :actor

      # Duplicate-submission guard: a queued or executing evaluation refuses
      # a new enqueue unless its execution is provably stranded (stale
      # heartbeat AND no other session holds the execution lock).
      def active_execution_error
        return nil unless evaluation.execution_pending?
        return "reviewer execution is already queued for this evaluation" if evaluation.queued? && heartbeat_fresh?

        if evaluation.executing? && heartbeat_fresh?
          return "reviewer execution is already in progress for this evaluation; retry once it finishes"
        end
        return "reviewer execution is already in progress for this evaluation; retry once it finishes" if ExecutionLock.held_by_other_session?(evaluation.id)

        nil
      end

      def heartbeat_fresh?
        heartbeat = evaluation.execute_heartbeat_at
        heartbeat.present? && heartbeat > STALE_EXECUTION_AFTER.ago
      end

      def enlist!
        evaluation.update!(
          status: "queued",
          cancel_requested_at: nil,
          last_failure_reason: nil,
          execute_heartbeat_at: Time.current,
          execution_attempts: evaluation.execution_attempts + 1
        )
        ExecuteJob.perform_later(evaluation.id)
        log_enqueued
      end

      def log_enqueued
        Rails.logger.info(
          message: "intent_conformance.shadow_execution_enqueued",
          project_id: evaluation.project_id,
          shadow_evaluation_id: evaluation.id,
          execution_attempts: evaluation.execution_attempts,
          actor_user_id: actor&.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, evaluation: nil, resumed: false)
      end
    end
  end
end
