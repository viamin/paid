# frozen_string_literal: true

module AppleVerificationAttempts
  # Starts the admitted VM, hands the closed-protocol job to the guest, and
  # routes the finished guest result through completion.
  # @spec APPLE-ATTEMPT-003
  # @spec APPLE-ATTEMPT-006
  # @spec APPLE-ATTEMPT-004
  class Provision
    # The timeout monitor runs every five minutes. Keep the request alive for
    # one full sweep after the attempt deadline so the monitor can destroy the
    # VM and interrupt the guest request before the transport itself expires.
    GUEST_DISPATCH_CANCELLATION_GRACE = 5.minutes

    def initialize(lifecycle:, guest_job: AppleVerification::ExecuteGuestJob, completion: Complete)
      @lifecycle = lifecycle
      @guest_job = guest_job
      @completion = completion
    end

    def call(attempt)
      raise ArgumentError, "an Apple verification attempt requires an agent run" unless attempt.agent_run

      handle = provision_active_attempt(attempt)
      return unless handle

      dispatch_guest_job(attempt, handle:)
      return unless mark_running(attempt)

      complete_guest_result(attempt)
    end

    private

    attr_reader :lifecycle, :guest_job, :completion

    def provision_active_attempt(attempt)
      attempt.with_lock do
        return if attempt.reload.terminal?

        attempt.update!(started_at: Time.current) unless attempt.started_at
        provision_vm(attempt)
      end
    end

    def provision_vm(attempt)
      lifecycle.provision(
        agent_run: attempt.agent_run,
        image_id: attempt.apple_worker_profile.image_digest,
        profile_id: attempt.apple_worker_profile.name,
        request_id: "apple-verification-attempt:#{attempt.id}:provision",
        apple_verification_attempt: attempt
      )
    end

    # The guest must receive its closed-protocol work before this attempt is
    # observable as running. Its request deadline spans the configured attempt
    # lifetime plus a small grace window in which the timeout monitor can
    # destroy the VM and interrupt the request. `export_artifacts` gives the
    # executor an explicit result handoff rather than leaving a provisioned VM
    # without a result path.
    def dispatch_guest_job(attempt, handle:)
      guest_job.call(
        agent_run: attempt.agent_run,
        image_digest: attempt.apple_worker_profile.image_digest,
        manifest: guest_manifest(attempt),
        guest_connection: AppleVerification::GuestConnection.new(
          connection: handle.metadata.fetch("guest_connection"),
          read_timeout: Config.attempt_timeout_minutes.minutes + GUEST_DISPATCH_CANCELLATION_GRACE
        )
      )
    end

    # The dispatch is synchronous: a normal return means the guest executor
    # finished the job and uploaded its output, so the attempt must leave
    # provisioning through {Complete} — terminal state, immediate destroy of
    # the successful VM, credential revocation — instead of occupying the
    # active slot until the timeout sweep. A dispatch raise leaves the attempt
    # non-terminal for TimeoutMonitor and Recovery.
    def complete_guest_result(attempt)
      attempt.with_lock do
        return if attempt.reload.terminal?

        completion.call(attempt:, outcome: "succeeded", lifecycle:)
      end
    end

    def mark_running(attempt)
      attempt.with_lock do
        return false if attempt.reload.terminal?

        attempt.update!(status: "running", started_at: attempt.started_at || Time.current)
        true
      end
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
