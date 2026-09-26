# frozen_string_literal: true

module AppleVerificationAttempts
  # Starts the admitted VM and records the transition into guest execution.
  # @spec APPLE-ATTEMPT-003
  class Provision
    def initialize(lifecycle:, guest_job: AppleVerification::ExecuteGuestJob, clock: Time)
      @lifecycle = lifecycle
      @guest_job = guest_job
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
      dispatch_guest_job(attempt)
      attempt.update!(status: "running", started_at: attempt.started_at || clock.current)
    end

    private

    attr_reader :lifecycle, :guest_job, :clock

    # The guest must receive its closed-protocol work before this attempt is
    # observable as running. `export_artifacts` gives the executor an explicit
    # result handoff rather than leaving a provisioned VM without a result path.
    def dispatch_guest_job(attempt)
      guest_job.call(
        agent_run: attempt.agent_run,
        image_digest: attempt.apple_worker_profile.image_digest,
        manifest: guest_manifest(attempt)
      )
    end

    def guest_manifest(attempt)
      {
        "version" => AppleVerification::GuestProtocol::VERSION,
        "operations" => [
          { "type" => "materialize_source", "payload" => { "digest" => attempt.source_digest } },
          { "type" => "export_artifacts", "payload" => {} }
        ]
      }
    end
  end
end
