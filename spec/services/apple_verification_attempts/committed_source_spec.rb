# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-007
RSpec.describe AppleVerificationAttempts::CommittedSource do
  let(:account) { create(:account) }
  let(:project) { create(:project, :with_github_installation, account: account) }
  let(:workflow) { create(:apple_verification_workflow_revision, project: project, account: account) }
  let(:attempt) do
    create(
      :apple_verification_attempt,
      :committed,
      project: project, account: account,
      apple_verification_workflow_revision: workflow
    )
  end

  let(:lane_result) do
    AppleVerification::SourceLane::CredentialLane::Result.new(
      installation_id: 99,
      repository_id: project.github_id || 1234,
      repo_full_name: project.full_name,
      ttl_seconds: 900
    )
  end

  it "mints a short-lived read-only credential for committed attempts and forwards the lane entry" do
    lane = instance_double(AppleVerification::SourceLane::CredentialLane)
    expect(lane).to receive(:call).and_return(lane_result)

    result = described_class.call(attempt: attempt, credential_lane: lane)

    expect(result.installation_id).to eq(99)
    expect(result.repository_full_name).to eq(project.full_name)
    expect(result.commit_sha).to eq(attempt.commit_sha)
    expect(result.lane_entry).to eq(
      "lane" => "credentials",
      "kind" => "github_app_installation",
      "locator" => {
        "installation_id" => 99,
        "repository_id" => lane_result.repository_id,
        "repo_full_name" => project.full_name,
        "ttl_seconds" => 900
      }
    )
    expect(AppleVerificationWorkers.lane_reference?(result.lane_entry, lane: "credentials")).to be(true)
  end

  it "revokes the cached credential through the lane" do
    lane = instance_double(AppleVerification::SourceLane::CredentialLane)
    expect(lane).to receive(:revoke!)

    described_class.new(attempt: attempt, credential_lane: lane).revoke
  end

  it "rejects uncommitted attempts because the credential lane is commit-only" do
    uncommitted = create(:apple_verification_attempt, project: project, account: account, apple_verification_workflow_revision: workflow)

    expect {
      described_class.call(attempt: uncommitted)
    }.to raise_error(ArgumentError, /committed/)
  end
end
