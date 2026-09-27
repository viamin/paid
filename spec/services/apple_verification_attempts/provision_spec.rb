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
    allow(guest_job).to receive(:call) do |**arguments|
      expect(attempt.reload.status).to eq("provisioning")
      expect(arguments).to include(
        agent_run: attempt.agent_run,
        image_digest: attempt.apple_worker_profile.image_digest,
        manifest: guest_manifest_for(attempt),
        guest_connection: have_attributes(read_timeout: 50.minutes)
      )
    end
    allow(completion).to receive(:call)

    described_class.new(lifecycle:, guest_job:, completion:).call(attempt)

    expect_provision_for(attempt, lifecycle)
    expect(guest_job).to have_received(:call)
    expect(completion).to have_received(:call).with(attempt:, outcome: "succeeded", lifecycle:)
    expect(attempt.reload.status).to eq("running")
  end

  # @spec APPLE-ATTEMPT-006
  it "completes the finished guest result with the success cleanup before leaving provisioning" do
    attempt = provisioning_attempt
    lifecycle = instance_double(AppleVerification::Lifecycle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    allow(lifecycle).to receive_messages(provision: provisioned_handle, destroy: :destroyed)
    allow(guest_job).to receive(:call)

    described_class.new(lifecycle:, guest_job:).call(attempt)

    expect(lifecycle).to have_received(:destroy).with(attempt:, request_id: "complete:#{attempt.id}")
    expect(attempt.reload).to have_attributes(status: "succeeded", failure_classification: nil)
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

  # @spec APPLE-ATTEMPT-004
  it "does not replace a timeout outcome when an in-flight guest call returns" do
    attempt = provisioning_attempt
    lifecycle = instance_double(AppleVerification::Lifecycle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    completion = class_double(AppleVerificationAttempts::Complete)
    allow(lifecycle).to receive(:provision).and_return(provisioned_handle)
    allow(guest_job).to receive(:call) { attempt.update!(status: "timed_out") }
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

  def guest_manifest_for(attempt)
    {
      "version" => AppleVerification::GuestProtocol::VERSION,
      "operations" => [
        { "type" => "materialize_source", "payload" => { "digest" => attempt.source_digest } },
        { "type" => "export_artifacts", "payload" => {} }
      ]
    }
  end
end
