# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Validate do
  # @spec APPLE-ATTEMPT-005
  let(:account) { create(:account) }
  let(:project) { create(:project, account:, apple_verification_mode: "on_demand") }
  let(:agent_run) { create(:agent_run, :running, project:) }
  let(:revision) { create(:apple_verification_workflow_revision, :approved, project:) }

  before do
    FeatureFlags.enable!(:apple_verification_workers, project:)
  end

  def attempt(**attrs)
    create(
      :apple_verification_attempt,
      project:,
      agent_run:,
      apple_verification_workflow_revision: revision,
      apple_worker_profile: revision.apple_worker_profile,
      lifecycle_gate: revision.lifecycle_gate,
      **attrs
    )
  end

  it "returns valid without mutating an eligible queued attempt" do
    subject = attempt

    result = described_class.call(attempt: subject)

    expect(result.valid).to be(true)
    expect(result.classification).to be_nil
    expect(result.reason).to be_nil
    expect(subject.reload.status).to eq("queued")
    expect(subject.finished_at).to be_nil
    expect(subject.failure_classification).to be_nil
  end

  it "marks the attempt failed with project_configuration when the project mode is off" do
    project.update!(apple_verification_mode: "off")
    subject = attempt

    result = described_class.call(attempt: subject)

    expect(result.valid).to be(false)
    expect(result.classification).to eq("project_configuration")
    expect(result.reason).to eq("project mode is off")
    subject.reload
    expect(subject.status).to eq("failed")
    expect(subject.failure_classification).to eq("project_configuration")
    expect(subject.finished_at).to be_present
  end

  it "marks the attempt failed with project_configuration when the feature flag is disabled" do
    FeatureFlags.disable!(:apple_verification_workers, project:)
    subject = attempt

    result = described_class.call(attempt: subject)

    expect(result.classification).to eq("project_configuration")
    expect(result.reason).to eq("feature flag disabled")
    expect(subject.reload).to have_attributes(status: "failed", failure_classification: "project_configuration")
  end

  it "marks the attempt failed with project_configuration for an ineligible workflow revision" do
    draft = create(:apple_verification_workflow_revision, project:, lifecycle_gate: "completion_verification")
    subject = build(
      :apple_verification_attempt,
      project:,
      agent_run:,
      apple_verification_workflow_revision: draft,
      apple_worker_profile: draft.apple_worker_profile,
      lifecycle_gate: draft.lifecycle_gate
    )
    subject.save(validate: false)

    result = described_class.call(attempt: subject)

    expect(result.classification).to eq("project_configuration")
    expect(result.reason).to eq("workflow revision not eligible")
    expect(subject.reload).to have_attributes(status: "failed", failure_classification: "project_configuration")
  end

  it "marks the attempt failed with project_configuration for an invalid source digest" do
    subject = attempt
    subject.update_column(:source_digest, "not-a-digest")
    subject.reload

    result = described_class.call(attempt: subject)

    expect(result.classification).to eq("project_configuration")
    expect(result.reason).to eq("source digest is invalid")
    expect(subject.reload).to have_attributes(status: "failed", failure_classification: "project_configuration")
  end

  it "marks the attempt failed with project_configuration for an invalid commit sha" do
    subject = attempt(commit_sha: "XYZ")

    result = described_class.call(attempt: subject)

    expect(result.classification).to eq("project_configuration")
    expect(result.reason).to eq("commit sha is invalid")
    expect(subject.reload).to have_attributes(status: "failed", failure_classification: "project_configuration")
  end

  it "marks the attempt failed with project_configuration when the run exceeds its attempts quota" do
    3.times { attempt(status: "succeeded", finished_at: Time.current) }
    subject = attempt

    result = described_class.call(attempt: subject)

    expect(result.classification).to eq("project_configuration")
    expect(result.reason).to eq("attempts per run quota exceeded")
    expect(subject.reload).to have_attributes(status: "failed", failure_classification: "project_configuration")
  end

  it "marks the attempt failed with unsupported_capability when the worker profile is revoked" do
    subject = attempt
    subject.apple_worker_profile.update!(status: "revoked")

    result = described_class.call(attempt: subject)

    expect(result.classification).to eq("unsupported_capability")
    expect(result.reason).to eq("worker profile unavailable")
    expect(subject.reload).to have_attributes(status: "failed", failure_classification: "unsupported_capability")
  end

  it "marks the attempt failed with unsupported_capability when the worker profile is quarantined" do
    subject = attempt
    subject.apple_worker_profile.update!(quarantined_at: Time.current)

    result = described_class.call(attempt: subject)

    expect(result).to have_attributes(valid: false, classification: "unsupported_capability", reason: "worker profile unavailable")
    expect(subject.reload).to have_attributes(status: "failed", failure_classification: "unsupported_capability")
  end

  it "returns the first failing check when multiple preconditions fail" do
    project.update!(apple_verification_mode: "off")
    subject = attempt
    subject.apple_worker_profile.update!(status: "revoked")

    result = described_class.call(attempt: subject)

    expect(result.classification).to eq("project_configuration")
    expect(result.reason).to eq("project mode is off")
  end
end
