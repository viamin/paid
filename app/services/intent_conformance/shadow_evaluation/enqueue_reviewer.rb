# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorizes a durable, idempotent hand-off. The HTTP request never invokes
    # the provider; ExecuteJob owns reviewer I/O and terminal state.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class EnqueueReviewer
      Result = Data.define(:success, :error, :enqueued) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return failure("reviewer execution requires a frozen reference label set") unless evaluation.answers_visible?
        return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless evaluation.corpus.matches_recorded_digest?

        enqueued = evaluation.with_lock do
          next false if evaluation.queued? || evaluation.running?

          evaluation.update!(status: "queued", execute_started_at: Time.current,
            execution_heartbeat_at: Time.current, cancellation_requested_at: nil, cancelled_at: nil,
            last_failure_reason: nil)
          true
        end
        if enqueued
          job = ExecuteJob.perform_later(evaluation.id)
          evaluation.update!(execution_job_id: job&.provider_job_id)
        end
        Result.new(success: true, error: nil, enqueued: enqueued)
      rescue ActiveJob::EnqueueError => error
        evaluation.update!(status: evaluation.runs.exists? ? "partial" : "frozen", last_failure_reason: error.message)
        failure("reviewer execution could not be queued")
      end

      private

      attr_reader :evaluation

      def failure(error) = Result.new(success: false, error:, enqueued: false)
    end
  end
end
