# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Provision do
  # @spec APPLE-ATTEMPT-003
  it "dispatches the guest manifest before recording the attempt as running" do
    attempt = provisioning_attempt
    lifecycle = instance_double(AppleVerification::Lifecycle)
    guest_job = class_double(AppleVerification::ExecuteGuestJob)
    allow(lifecycle).to receive(:provision)
    allow(guest_job).to receive(:call) do |**arguments|
      expect(attempt.reload.status).to eq("provisioning")
      expect(arguments).to include(
        agent_run: attempt.agent_run,
        image_digest: attempt.apple_worker_profile.image_digest,
        manifest: guest_manifest_for(attempt)
      )
    end

    described_class.new(lifecycle:, guest_job:).call(attempt)

    expect(lifecycle).to have_received(:provision)
    expect(guest_job).to have_received(:call)
    expect(attempt.reload.status).to eq("running")
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
