# frozen_string_literal: true

module AppleVerificationAttempts
  # Starts the admitted VM, hands the closed-protocol job to the guest, and
  # routes the finished guest result through completion.
  # @spec APPLE-ATTEMPT-003
  # @spec APPLE-ATTEMPT-006
  class Provision
    def initialize(lifecycle:, guest_job: AppleVerification::ExecuteGuestJob, completion: Complete, clock: Time)
      @lifecycle = lifecycle
      @guest_job = guest_job
      @completion = completion
      @clock = clock
    end

    def call(attempt)
      raise ArgumentError, "an Apple verification attempt requires an agent run" unless attempt.agent_run

      handle = provision_vm(attempt)
      dispatch_guest_job(attempt, handle:)
      attempt.update!(status: "running", started_at: attempt.started_at || clock.current)
      complete_guest_result(attempt)
    end

    private

    attr_reader :lifecycle, :guest_job, :completion, :clock

    def provision_vm(attempt)
      lifecycle.provision(
        agent_run: attempt.agent_run,
        image_id: attempt.apple_worker_profile.image_digest,
        profile_id: attempt.apple_worker_profile_id,
        request_id: "apple-verification-attempt:#{attempt.id}:provision",
        apple_verification_attempt: attempt
      )
    rescue Faraday::Error, Timeout::Error
      WorkerHealth.new(profile: attempt.apple_worker_profile).record_failure
      raise
    end

    # The guest must receive its closed-protocol work before this attempt is
    # observable as running. `export_artifacts` gives the executor an explicit
    # result handoff rather than leaving a provisioned VM without a result path.
    def dispatch_guest_job(attempt, handle:)
      guest_job.call(
        agent_run: attempt.agent_run,
        image_digest: attempt.apple_worker_profile.image_digest,
        manifest: guest_manifest(attempt),
        guest_connection: AppleVerification::GuestConnection.new(connection: handle.metadata.fetch("guest_connection"))
      )
    end

    # The dispatch is synchronous: a normal return means the guest executor
    # finished the job and uploaded its output, so the attempt must leave
    # provisioning through {Complete} — terminal state, immediate destroy of
    # the successful VM, credential revocation — instead of occupying the
    # active slot until the timeout sweep. A dispatch raise leaves the attempt
    # non-terminal for TimeoutMonitor and Recovery.
    def complete_guest_result(attempt)
      completion.call(attempt:, status: "succeeded", lifecycle:, clock:)
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
