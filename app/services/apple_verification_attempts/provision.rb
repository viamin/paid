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

    def initialize(lifecycle:, guest_job: AppleVerification::ExecuteGuestJob, completion: Complete,
      source_lane: AppleVerification::SourceLane::Build,
      artifact_ingestion: AppleVerification::ArtifactIngestion::Ingest,
      result_manifest: AppleVerification::ResultManifest::Build,
      artifact_storage: AppleVerification::ArtifactIngestion::Storage.new,
      host_mount_check:)
      @lifecycle = lifecycle
      @guest_job = guest_job
      @completion = completion
      @source_lane = source_lane
      @artifact_ingestion = artifact_ingestion
      @result_manifest = result_manifest
      @artifact_storage = artifact_storage
      @host_mount_check = host_mount_check
    end

    def call(attempt)
      raise ArgumentError, "an Apple verification attempt requires an agent run" unless attempt.agent_run

      source_lanes = validated_source_lanes(attempt)
      handle = provision_active_attempt(attempt)
      return unless handle

      result = dispatch_guest_job(attempt, handle:, source_lanes:)
      return unless mark_running(attempt)

      complete_guest_result(attempt, result:, source_lanes:)
    end

    private

    attr_reader :lifecycle, :guest_job, :completion, :source_lane, :artifact_ingestion, :result_manifest, :artifact_storage, :host_mount_check

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

    def validated_source_lanes(attempt)
      lanes = source_lane.call(attempt:, host_mount_check:).to_h.deep_stringify_keys
      AppleVerificationWorkers::InputManifest.new(
        source: source_section(attempt),
        verification: { "operations" => [] },
        profile: { "digest" => attempt.apple_worker_profile.image_digest },
        lanes: lanes
      )
      lanes
    end

    def source_section(attempt)
      { "digest" => attempt.source_digest, "commit_sha" => attempt.commit_sha, "bundle_digest" => bundle_digest(attempt) }.compact
    end

    def bundle_digest(attempt)
      attempt.source_digest unless attempt.commit_sha.present?
    end

    # The guest must receive its closed-protocol work before this attempt is
    # observable as running. Its request deadline spans the configured attempt
    # lifetime plus a small grace window in which the timeout monitor can
    # destroy the VM and interrupt the request. `export_artifacts` gives the
    # executor an explicit result handoff rather than leaving a provisioned VM
    # without a result path.
    def dispatch_guest_job(attempt, handle:, source_lanes:)
      guest_job.call(
        agent_run: attempt.agent_run,
        image_digest: attempt.apple_worker_profile.image_digest,
        manifest: guest_manifest(attempt, source_lanes:),
        guest_connection: AppleVerification::GuestConnection.new(
          connection: usable_connection(handle),
          read_timeout: Config.attempt_timeout_minutes.minutes + GUEST_DISPATCH_CANCELLATION_GRACE
        )
      )
    end

    # The host may reply to `start` with a readiness-only payload (for example
    # `{ "ready" => true }`) before it can hand back the guest executor's own
    # URL. Passing that payload straight through as the connection would make
    # {AppleVerification::GuestConnection} raise `ConfigurationError` instead
    # of falling back to the image's validated `guest_executor_url`
    # provenance, so only forward a connection override that actually carries
    # a usable url.
    def usable_connection(handle)
      connection = handle.metadata.fetch("guest_connection", nil) if handle.metadata.is_a?(Hash)
      connection if connection.is_a?(Hash) && connection["url"].present?
    end

    # The dispatch is synchronous, but a normal HTTP response is not proof of
    # verification. Derive the terminal outcome from every guest operation so
    # a missing or failed required check cannot unblock a completion gate.
    # A dispatch raise leaves the attempt non-terminal for TimeoutMonitor and
    # Recovery.
    def complete_guest_result(attempt, result:, source_lanes:)
      attempt.with_lock do
        return if attempt.reload.terminal?

        outcome = GuestResult.call(
          revision: attempt.apple_verification_workflow_revision,
          manifest: guest_manifest(attempt, source_lanes:),
          operations: result.operations
        )
        persist_transport_result(attempt, result:, outcome:)
        completion.call(attempt:, outcome: outcome.status, failure_classification: outcome.failure_classification, lifecycle:)
      end
    end

    def persist_transport_result(attempt, result:, outcome:)
      references = artifact_ingestion.call(attempt:, descriptors: artifact_descriptors(result), storage: artifact_storage).references
      persist_artifacts(attempt, references)
      persist_result_manifest(attempt, references, outcome:)
    end

    def artifact_descriptors(result)
      Array(result.operations).filter_map { |operation| operation["artifacts"] if operation["type"] == "export_artifacts" }.flatten
    end

    def persist_artifacts(attempt, references)
      references.each do |reference|
        AppleVerificationArtifact.create!(
          apple_verification_attempt: attempt,
          kind: reference.fetch("kind"),
          storage_key: reference.dig("locator", "key"),
          metadata: { "locator" => reference.fetch("locator") },
          expires_at: AppleVerification::ArtifactIngestion::Storage::DEFAULT_BINARY_RETENTION_DAYS.days.from_now
        )
      end
    end

    def persist_result_manifest(attempt, references, outcome:)
      manifest = result_manifest.call(
        attempt:,
        artifact_references: references,
        status: outcome.status,
        failure_classification: outcome.failure_classification,
        timings: timings(attempt)
      ).manifest.as_json
      AppleVerificationArtifact.create!(
        apple_verification_attempt: attempt,
        kind: "manifest",
        storage_key: "apple-verification/#{attempt.account_id}/#{attempt.project_id}/#{attempt.id}/manifest/result.json",
        metadata: { "manifest" => manifest }
      )
    end

    def timings(attempt)
      finished_at = attempt.finished_at || Time.current
      started_at = attempt.started_at || finished_at
      queued_at = attempt.queue_entered_at || started_at
      {
        "queued_ms" => ((started_at - queued_at) * 1000).round,
        "provisioning_ms" => 0,
        "running_ms" => ((finished_at - started_at) * 1000).round,
        "total_ms" => ((finished_at - queued_at) * 1000).round
      }
    end

    def mark_running(attempt)
      attempt.with_lock do
        return false if attempt.reload.terminal?

        attempt.update!(status: "running", started_at: attempt.started_at || Time.current)
        true
      end
    end

    def guest_manifest(attempt, source_lanes:)
      # An approved revision currently persists the required check identifiers,
      # not the protocol payloads (scheme, bundle ID, and declared UI flow)
      # needed to execute them. Do not invent those values here: GuestResult
      # fails this manifest closed whenever the revision requires test or
      # capture work, so a 2xx response can never satisfy that verification.
      {
        "version" => AppleVerification::GuestProtocol::VERSION,
        "source_lanes" => source_lanes,
        "operations" => [
          { "type" => "materialize_source", "payload" => { "digest" => attempt.source_digest } },
          { "type" => "export_artifacts", "payload" => {} }
        ]
      }
    end
  end
end
