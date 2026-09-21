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

      @attempt.project.apple_verification_attempts.create_or_find_by!(retry_of_attempt: @attempt) do |rerun_attempt|
        rerun_attempt.assign_attributes(
          account: @attempt.account,
          agent_run: @attempt.agent_run,
          apple_verification_workflow_revision: @attempt.apple_verification_workflow_revision,
          apple_worker_profile: @attempt.apple_worker_profile,
          source_digest: @attempt.source_digest,
          commit_sha: @attempt.commit_sha,
          lifecycle_gate: @attempt.lifecycle_gate,
          retry_number: @attempt.retry_number + 1,
          status: "queued"
        )
      end
    end
  end
end
