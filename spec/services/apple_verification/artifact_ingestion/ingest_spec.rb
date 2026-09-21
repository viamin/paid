# frozen_string_literal: true

require "rails_helper"
require "aws-sdk-s3"

# @spec APPLE-TRANSFER-005
RSpec.describe AppleVerification::ArtifactIngestion::Ingest do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:workflow_revision) { create(:apple_verification_workflow_revision, project: project, account: account) }
  let(:attempt) { create(:apple_verification_attempt, apple_verification_workflow_revision: workflow_revision, project: project, account: account) }

  let(:storage) { instance_double(AppleVerification::ArtifactIngestion::Storage) }
  let(:s3_client) { instance_double(Aws::S3::Client) }

  before do
    allow(storage).to receive_messages(
      upload_bytes: "apple-verification/#{attempt.account_id}/#{attempt.project_id}/#{attempt.id}/xcresult/App.xcresult",
      signed_url: "https://example.com/key"
    )
  end

  around do |example|
    FeatureFlags.enable!(:apple_verification_workers, project: project)
    example.run
  ensure
    FeatureFlags.disable!(:apple_verification_workers, project: project)
  end

  it "ingests each descriptor into a typed object-storage lane reference" do
    result = described_class.call(
      attempt: attempt,
      descriptors: [
        { "kind" => "xcresult", "name" => "App.xcresult", "bytes" => "binary-xcresult" },
        { "kind" => "build_log", "name" => "build.log", "bytes" => "Build succeeded" },
        { "kind" => "screenshot", "name" => "first.png", "bytes" => "PNG" }
      ],
      storage: storage
    )

    expect(result.references.length).to eq(3)
    expect(result.references.first).to include(
      "lane" => "object_storage",
      "kind" => "xcresult",
      "name" => "App.xcresult",
      "content_type" => "application/x-xcresult"
    )
    expect(result.references.first["locator"]).to include("url" => "https://example.com/key")
  end

  it "rejects host path or host mount fields in any descriptor" do
    expect {
      described_class.call(
        attempt: attempt,
        descriptors: [ { "kind" => "xcresult", "name" => "App.xcresult", "bytes" => "x", "host_path" => "/tmp" } ],
        storage: storage
      )
    }.to raise_error(described_class::HostPathError, /host_path/)
  end

  it "rejects descriptors with empty payloads" do
    expect {
      described_class.call(
        attempt: attempt,
        descriptors: [ { "kind" => "xcresult", "name" => "App.xcresult", "bytes" => "" } ],
        storage: storage
      )
    }.to raise_error(described_class::EmptyArtifactError)
  end

  it "rejects descriptors with unsupported kinds" do
    expect {
      described_class.call(
        attempt: attempt,
        descriptors: [ { "kind" => "raw_shell", "name" => "shell.sh", "bytes" => "rm -rf /" } ],
        storage: storage
      )
    }.to raise_error(described_class::UnsupportedKindError)
  end

  it "rejects descriptors with names that escape the namespace" do
    expect {
      described_class.call(
        attempt: attempt,
        descriptors: [ { "kind" => "xcresult", "name" => "../../etc/passwd", "bytes" => "x" } ],
        storage: storage
      )
    }.to raise_error(described_class::HostPathError, /host path/)
  end

  it "rejects descriptors when the workflow profile is revoked" do
    attempt.apple_worker_profile.update!(status: "revoked")

    expect {
      described_class.call(
        attempt: attempt,
        descriptors: [ { "kind" => "xcresult", "name" => "App.xcresult", "bytes" => "x" } ],
        storage: storage
      )
    }.to raise_error(described_class::RevokedProfileError)
  end

  it "rejects descriptors when the rollout flag is disabled" do
    FeatureFlags.disable!(:apple_verification_workers, project: project)

    expect {
      described_class.call(
        attempt: attempt,
        descriptors: [ { "kind" => "xcresult", "name" => "App.xcresult", "bytes" => "x" } ],
        storage: storage
      )
    }.to raise_error(described_class::DisabledError)
  end
end
