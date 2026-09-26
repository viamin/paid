# frozen_string_literal: true

module AppleVerificationAttempts
  # Starts the admitted VM and records the transition into guest execution.
  # @spec APPLE-ATTEMPT-003
  class Provision
    def initialize(lifecycle:, clock: Time)
      @lifecycle = lifecycle
      @clock = clock
    end

    def call(attempt)
      raise ArgumentError, "an Apple verification attempt requires an agent run" unless attempt.agent_run

      lifecycle.provision(
        agent_run: attempt.agent_run,
        image_id: attempt.apple_worker_profile.image_digest,
        profile_id: attempt.apple_worker_profile_id,
        request_id: "apple-verification-attempt:#{attempt.id}:provision",
        apple_verification_attempt: attempt
      )
      attempt.update!(status: "running", started_at: attempt.started_at || clock.current)
    end

    private

    attr_reader :lifecycle, :clock
  end
end
