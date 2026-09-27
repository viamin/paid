# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Provision do
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

    described_class.new(lifecycle:, guest_job:, completion:).call(attempt)

    expect_provision_for(attempt, lifecycle)
    expect(guest_job).to have_received(:call)
    expect(completion).to have_received(:call).with(
      attempt:, outcome: "failed", failure_classification: "project_configuration", lifecycle:
    )
    expect(attempt.reload.status).to eq("running")
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

    described_class.new(lifecycle:, guest_job:, completion:).call(attempt)

    # A `connection:` of nil (rather than the url-less `{ "ready" => true }` the host
    # returned) is what lets AppleVerification::GuestConnection fall back to the
    # image's validated `guest_executor_url` provenance instead of raising
    # ConfigurationError. See guest_connection_spec.rb for that fallback dispatch.
    expect(AppleVerification::GuestConnection).to have_received(:new).with(connection: nil, read_timeout: anything)
  end

  # @spec APPLE-ATTEMPT-006
  it "completes the finished guest result with the success cleanup before leaving provisioning" do
    attempt = provisioning_attempt
    lifecycle = instance_double(AppleVerification::Lifecycle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    allow(lifecycle).to receive_messages(provision: provisioned_handle, destroy: :destroyed, stop: :stopped)
    allow(guest_job).to receive(:call).and_return(guest_result_for(guest_manifest_for(attempt)))

    described_class.new(lifecycle:, guest_job:).call(attempt)

    expect(attempt.reload).to have_attributes(status: "failed", failure_classification: "project_configuration")
    expect(attempt.reload.finished_at).to be_present
  end

  it "leaves the attempt non-terminal for the timeout monitor when guest dispatch fails" do
    attempt = provisioning_attempt
    lifecycle = instance_double(AppleVerification::Lifecycle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    completion = class_double(AppleVerificationAttempts::Complete)
    allow(lifecycle).to receive(:provision).and_return(provisioned_handle)
    allow(guest_job).to receive(:call).and_raise(AppleVerification::GuestConnection::DispatchError, "executor unreachable")
    allow(completion).to receive(:call)

    expect { described_class.new(lifecycle:, guest_job:, completion:).call(attempt) }
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

    described_class.new(lifecycle:, guest_job:, completion:).call(attempt)

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

    described_class.new(lifecycle:, guest_job:, completion:).call(attempt)

    expect(completion).not_to have_received(:call)
    expect(attempt.reload.status).to eq("timed_out")
  end

  def provisioning_attempt
    project = create(:project)
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
        manifest: guest_manifest_for(attempt), guest_connection: have_attributes(read_timeout: 50.minutes)
      )
      guest_result_for(guest_manifest_for(attempt))
    end
  end

  def guest_manifest_for(attempt)
    {
      "version" => AppleVerification::GuestProtocol::VERSION,
      "operations" => [
        { "type" => "materialize_source", "payload" => { "digest" => attempt.source_digest } },
        { "type" => "export_artifacts", "payload" => {} }
      ]
    }
  end

  def guest_result_for(manifest)
    AppleVerification::ExecuteGuestJob::Result.new(
      image: nil,
      operations: manifest.fetch("operations").map { |operation| { "type" => operation.fetch("type"), "status" => "succeeded" } }
    )
  end
end
