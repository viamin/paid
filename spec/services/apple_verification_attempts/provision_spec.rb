# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Provision do
  let(:host_mount_check) { ->(_agent_run) { false } }

  around do |example|
    FeatureFlags.enable!(:apple_verification_workers, project: example.metadata[:project]) if example.metadata[:project]
    example.run
  end

  # @spec APPLE-ATTEMPT-004
  # @spec APPLE-TRANSFER-001
  # @spec APPLE-TRANSFER-004
  # @spec APPLE-TRANSFER-005
  it "transports committed source, records workflow checks and screenshot metadata, and refreshes the manifest after completion" do
    project = create(:project, :with_github_installation)
    attempt = create(:apple_verification_attempt, :committed, status: "provisioning", project:, account: project.account,
      agent_run: create(:agent_run, project:))
    attempt.update!(started_at: 5.minutes.ago, queue_entered_at: 6.minutes.ago)
    FeatureFlags.enable!(:apple_verification_workers, project:)
    lifecycle = instance_double(AppleVerification::Lifecycle, provision: provisioned_handle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    completion = class_double(AppleVerificationAttempts::Complete)
    storage = instance_double(AppleVerification::ArtifactIngestion::Storage)
    allow(storage).to receive_messages(
      upload_bytes: "apple-verification/screenshot.png",
      signed_url: "https://storage.example.test/screenshot.png"
    )

    stub_transport_guest(guest_job, attempt)
    stub_transport_completion(completion, attempt)

    described_class.new(lifecycle:, guest_job:, completion:, artifact_storage: storage, host_mount_check:).call(attempt)

    expect_persisted_transport(attempt, storage)
  ensure
    FeatureFlags.disable!(:apple_verification_workers, project:) if project
  end

  # @spec APPLE-ATTEMPT-006
  # @spec APPLE-TRANSFER-005
  it "leaves a result with invalid artifacts recoverable instead of completing the attempt" do
    attempt = provisioning_attempt
    lifecycle = instance_double(AppleVerification::Lifecycle, provision: provisioned_handle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    completion = class_double(AppleVerificationAttempts::Complete)
    allow(guest_job).to receive(:call).and_return(
      guest_result_for(guest_manifest_for(attempt)).tap do |result|
        result.operations.last["artifacts"] = [ { "kind" => "unknown", "name" => "result", "bytes" => "payload" } ]
      end
    )
    allow(completion).to receive(:call)

    expect { described_class.new(lifecycle:, guest_job:, completion:, host_mount_check:).call(attempt) }
      .to raise_error(AppleVerification::ArtifactIngestion::Ingest::UnsupportedKindError)

    expect(completion).not_to have_received(:call)
    expect(attempt.reload.status).to eq("running")
    expect(attempt.apple_verification_artifacts).to be_empty
  end

  # @spec APPLE-ATTEMPT-004
  # @spec APPLE-ATTEMPT-003
  it "dispatches the guest manifest before recording the attempt as running" do
    attempt = provisioning_attempt
    lifecycle = instance_double(AppleVerification::Lifecycle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    completion = class_double(AppleVerificationAttempts::Complete)
    allow(lifecycle).to receive(:provision).and_return(provisioned_handle)
    stub_guest_dispatch(guest_job, attempt)
    allow(completion).to receive(:call)

    described_class.new(lifecycle:, guest_job:, completion:, host_mount_check:).call(attempt)

    expect_provision_for(attempt, lifecycle)
    expect(guest_job).to have_received(:call)
    expect(completion).to have_received(:call).with(
      attempt:, outcome: "succeeded", failure_classification: nil, lifecycle:
    )
    expect(attempt.reload.status).to eq("running")
  end

  # @spec APPLE-WORKER-013
  # @spec APPLE-ATTEMPT-009
  it "derives approved build, test, and capture operations from the bound configuration" do
    attempt = provisioning_attempt
    bind_configuration(attempt.apple_verification_workflow_revision, capture_workflow_yaml)
    lifecycle = instance_double(AppleVerification::Lifecycle, provision: provisioned_handle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    completion = class_double(AppleVerificationAttempts::Complete)
    dispatched_manifest = nil
    allow(completion).to receive(:call)
    allow(guest_job).to receive(:call) do |manifest:, **|
      dispatched_manifest = manifest
      guest_result_for(manifest)
    end

    described_class.new(lifecycle:, guest_job:, completion:, host_mount_check:).call(attempt)

    expect(dispatched_manifest.fetch("operations").map { |operation| operation.fetch("type") }).to eq(
      %w[materialize_source resolve_swift_packages build test launch_app ui_action capture export_artifacts]
    )
    expect(dispatched_manifest.dig("operations", 6, "payload")).to include("platform" => "ios", "target" => "simulator_screen")
    expect(completion).to have_received(:call).with(attempt:, outcome: "succeeded", failure_classification: nil, lifecycle:)
  end

  # @spec APPLE-ATTEMPT-004
  it "falls back to the image's guest executor url instead of a readiness-only host connection payload" do
    attempt = provisioning_attempt
    lifecycle = instance_double(AppleVerification::Lifecycle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    completion = class_double(AppleVerificationAttempts::Complete)
    allow(lifecycle).to receive(:provision).and_return(
      instance_double(ExecutionRunners::RunnerHandle, metadata: { "guest_connection" => { "ready" => true } })
    )
    allow(completion).to receive(:call)
    allow(guest_job).to receive(:call).and_return(guest_result_for(guest_manifest_for(attempt)))
    allow(AppleVerification::GuestConnection).to receive(:new).and_call_original

    described_class.new(lifecycle:, guest_job:, completion:, host_mount_check:).call(attempt)

    # A `connection:` of nil (rather than the url-less `{ "ready" => true }` the host
    # returned) is what lets AppleVerification::GuestConnection fall back to the
    # image's validated `guest_executor_url` provenance instead of raising
    # ConfigurationError. See guest_connection_spec.rb for that fallback dispatch.
    expect(AppleVerification::GuestConnection).to have_received(:new).with(connection: nil, read_timeout: anything)
  end

  # @spec APPLE-ATTEMPT-004
  it "falls back to the image's guest executor url when the host omits connection metadata" do
    attempt = provisioning_attempt
    lifecycle = instance_double(AppleVerification::Lifecycle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    completion = class_double(AppleVerificationAttempts::Complete)
    allow(lifecycle).to receive(:provision).and_return(
      instance_double(ExecutionRunners::RunnerHandle, metadata: {})
    )
    allow(completion).to receive(:call)
    allow(guest_job).to receive(:call).and_return(guest_result_for(guest_manifest_for(attempt)))
    allow(AppleVerification::GuestConnection).to receive(:new).and_call_original

    described_class.new(lifecycle:, guest_job:, completion:, host_mount_check:).call(attempt)

    expect(AppleVerification::GuestConnection).to have_received(:new).with(connection: nil, read_timeout: anything)
  end

  # @spec APPLE-ATTEMPT-006
  it "completes the finished guest result with the success cleanup before leaving provisioning" do
    attempt = provisioning_attempt
    ledger_entry = create(:execution_resource_ledger_entry, :active,
      entry_account: attempt.account,
      project: attempt.project,
      agent_run: attempt.agent_run,
      apple_verification_attempt: attempt,
      runner_type: "apple_tart",
      backend: "tart",
      resource_kind: "verification_vm")
    lifecycle = instance_double(AppleVerification::Lifecycle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    allow(lifecycle).to receive_messages(provision: provisioned_handle, destroy: :destroyed, stop: :stopped)
    allow(guest_job).to receive(:call).and_return(guest_result_for(guest_manifest_for(attempt)))

    described_class.new(lifecycle:, guest_job:, host_mount_check:).call(attempt)

    expect(attempt.reload).to have_attributes(status: "succeeded", failure_classification: nil)
    expect(attempt.reload.finished_at).to be_present
    manifest = attempt.apple_verification_artifacts.find_by!(kind: "manifest").metadata.fetch("manifest")
    expect(manifest.dig("result", "audit_event_references")).to match_array(attempt.execution_audit_events.pluck(:id).map(&:to_s))
    expect(manifest.dig("result", "ledger_entry_references")).to eq([ ledger_entry.id.to_s ])
  end

  it "leaves the attempt non-terminal for the timeout monitor when guest dispatch fails" do
    attempt = provisioning_attempt
    lifecycle = instance_double(AppleVerification::Lifecycle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    completion = class_double(AppleVerificationAttempts::Complete)
    allow(lifecycle).to receive(:provision).and_return(provisioned_handle)
    allow(guest_job).to receive(:call).and_raise(AppleVerification::GuestConnection::DispatchError, "executor unreachable")
    allow(completion).to receive(:call)

    expect { described_class.new(lifecycle:, guest_job:, completion:, host_mount_check:).call(attempt) }
      .to raise_error(AppleVerification::GuestConnection::DispatchError)

    expect(completion).not_to have_received(:call)
    expect(attempt.reload.status).to eq("provisioning")
  end

  # @spec APPLE-ATTEMPT-009
  it "classifies a failed required guest operation instead of accepting its HTTP response as success" do
    attempt = provisioning_attempt
    lifecycle = instance_double(AppleVerification::Lifecycle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    completion = class_double(AppleVerificationAttempts::Complete)
    allow(lifecycle).to receive(:provision).and_return(provisioned_handle)
    allow(guest_job).to receive(:call).and_return(
      guest_result_for(
        "operations" => [
          { "type" => "materialize_source", "payload" => { "digest" => attempt.source_digest } },
          { "type" => "test", "payload" => { "scheme" => "App" } },
          { "type" => "export_artifacts", "payload" => {} }
        ]
      ).tap { |result| result.operations[1]["status"] = "failed" }
    )
    allow(completion).to receive(:call)

    described_class.new(lifecycle:, guest_job:, completion:, host_mount_check:).call(attempt)

    expect(completion).to have_received(:call).with(
      attempt:, outcome: "failed", failure_classification: "test_assertion", lifecycle:
    )
  end

  # @spec APPLE-ATTEMPT-004
  it "does not replace a timeout outcome when an in-flight guest call returns" do
    attempt = provisioning_attempt
    lifecycle = instance_double(AppleVerification::Lifecycle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    completion = class_double(AppleVerificationAttempts::Complete)
    allow(lifecycle).to receive(:provision).and_return(provisioned_handle)
    allow(guest_job).to receive(:call) do
      attempt.update!(status: "timed_out")
      AppleVerification::ExecuteGuestJob::Result.new(image: nil, operations: [])
    end
    allow(completion).to receive(:call)

    described_class.new(lifecycle:, guest_job:, completion:, host_mount_check:).call(attempt)

    expect(completion).not_to have_received(:call)
    expect(attempt.reload.status).to eq("timed_out")
  end

  def provisioning_attempt
    project = create(:project)
    FeatureFlags.enable!(:apple_verification_workers, project:)
    create(
      :apple_verification_attempt,
      status: "provisioning",
      project:,
      account: project.account,
      agent_run: create(:agent_run, project:)
    )
  end

  def provisioned_handle
    instance_double(
      ExecutionRunners::RunnerHandle,
      metadata: { "guest_connection" => { "url" => "https://vm-1.example.test/v1/jobs" } }
    )
  end

  def expect_provision_for(attempt, lifecycle)
    expect(lifecycle).to have_received(:provision).with(
      agent_run: attempt.agent_run, image_id: attempt.apple_worker_profile.image_digest,
      profile_id: attempt.apple_worker_profile.name,
      request_id: "apple-verification-attempt:#{attempt.id}:provision", apple_verification_attempt: attempt
    )
  end

  def stub_guest_dispatch(guest_job, attempt)
    allow(guest_job).to receive(:call) do |**arguments|
      expect(attempt.reload.status).to eq("provisioning")
      expect(arguments).to include(
        agent_run: attempt.agent_run, image_digest: attempt.apple_worker_profile.image_digest,
        guest_connection: have_attributes(read_timeout: 50.minutes)
      )
      expect(arguments.fetch(:manifest)).to include("version" => AppleVerification::GuestProtocol::VERSION)
      guest_result_for(guest_manifest_for(attempt))
    end
  end

  def guest_manifest_for(attempt)
    { "operations" => AppleVerification::GuestManifest::Build.call(attempt:) }
  end

  def stub_transport_guest(guest_job, attempt)
    allow(guest_job).to receive(:call) do |manifest:, **|
      expect(manifest.dig("source_lanes", "git", 0, "locator", "commit_sha")).to eq(attempt.commit_sha)
      expect(manifest.dig("source_lanes", "credentials", 0, "kind")).to eq("github_app_installation")
      guest_result_for(manifest).tap { |result| result.operations.last["artifacts"] = [ { "kind" => "screenshot", "name" => "screen.png", "bytes" => "png" } ] }
    end
  end

  def stub_transport_completion(completion, attempt)
    allow(completion).to receive(:call) do
      expect(attempt.apple_verification_artifacts.find_by(kind: "manifest")).to be_present
    end
  end

  def expect_persisted_transport(attempt, storage)
    expect(storage).to have_received(:upload_bytes).with(hash_including(attempt_id: attempt.id, kind: "screenshot", name: "screen.png"))
    expect(attempt.apple_verification_artifacts.find_by!(kind: "screenshot").storage_key).to eq("apple-verification/screenshot.png")
    manifest = attempt.apple_verification_artifacts.find_by!(kind: "manifest").metadata.fetch("manifest")
    expect(manifest.fetch("result")).to include(
      "status" => "succeeded",
      "failure_classification" => nil,
      "required_checks" => attempt.apple_verification_workflow_revision.required_checks,
      "advisory_checks" => attempt.apple_verification_workflow_revision.advisory_checks,
      "screenshot_metadata" => [ "apple-verification/screenshot.png" ]
    )
    expect(manifest.dig("result", "timings", "provisioning_ms")).to be > 0
    expect(manifest.dig("result", "timings", "running_ms")).to be < manifest.dig("result", "timings", "provisioning_ms")
  end

  def guest_result_for(manifest)
    AppleVerification::ExecuteGuestJob::Result.new(
      image: nil,
      operations: manifest.fetch("operations").map { |operation| { "type" => operation.fetch("type"), "status" => "succeeded" } }
    )
  end

  def bind_configuration(revision, content)
    revision.update_columns(configuration_content: content, content_digest: "sha256:#{Digest::SHA256.hexdigest(content)}")
  end

  def capture_workflow_yaml
    <<~YAML
      version: 1
      profiles:
        ios-app:
          platform: ios
          xcode:
            project: App.xcodeproj
            scheme: App
          bootstrap: spm
          tests:
            required: true
          captures:
            - id: initial-screen
              required: true
              flow: [ { launch_app: {} }, { wait_for_accessibility_id: { id: main-screen } }, { capture: { name: initial-screen } } ]
    YAML
  end
end
