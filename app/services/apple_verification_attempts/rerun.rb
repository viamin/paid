# frozen_string_literal: true

module AppleVerificationAttempts
  # Queues an immutable retry from a completed attempt.
  # @spec APPLE-VERIFY-006
  class Rerun
    def self.call(attempt:)
      new(attempt:).call
    end

    def initialize(attempt:)
      @attempt = attempt
    end

    def call
      raise ArgumentError, "only a completed attempt can be rerun" unless @attempt.terminal?
      raise ArgumentError, "attempt failure is not retryable" unless RetryPolicy.call(attempt: @attempt).retryable

      return existing_retry if existing_retry

      # The insert and the queue admission share one transaction so a queue
      # limit refusal rolls the queued rerun back instead of stranding a
      # phantom attempt the scheduler would later admit.
      AppleVerificationAttempt.transaction do
        raise ArgumentError, "Apple verification queue is full" if Queue.full?
        raise ArgumentError, "Apple verification attempt limit reached for agent run" if agent_run_limit_reached?

        @attempt.project.apple_verification_attempts.create_or_find_by!(retry_of_attempt: @attempt) do |rerun_attempt|
          rerun_attempt.assign_attributes(retry_attributes)
        end
      end
    end

    private

    def existing_retry
      @attempt.retry_attempt
    end

    def agent_run_limit_reached?
      @attempt.agent_run && AppleVerificationAttempt.where(agent_run: @attempt.agent_run).count >= Config.max_attempts_per_run
    end

    def retry_attributes
      {
        account: @attempt.account,
        agent_run: @attempt.agent_run,
        apple_verification_workflow_revision: @attempt.apple_verification_workflow_revision,
        apple_worker_profile: @attempt.apple_worker_profile,
        source_digest: @attempt.source_digest,
        commit_sha: @attempt.commit_sha,
        requested_capture: @attempt.requested_capture,
        lifecycle_gate: @attempt.lifecycle_gate,
        retry_number: @attempt.retry_number + 1,
        status: "queued",
        retry_of_attempt: @attempt
      }
    end
  end
end
