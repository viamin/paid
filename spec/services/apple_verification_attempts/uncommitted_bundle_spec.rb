# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-008
RSpec.describe AppleVerificationAttempts::UncommittedBundle do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:workflow) { create(:apple_verification_workflow_revision, project: project, account: account) }
  let(:attempt) do
    create(
      :apple_verification_attempt,
      project: project, account: account,
      apple_verification_workflow_revision: workflow
    )
  end

  it "builds a content-addressed workspace bundle from the supplied workspace" do
    Dir.mktmpdir do |workspace_root|
      File.write(File.join(workspace_root, "App.swift"), "print(\"hello\")")

      builder = build_stub_builder

      result = described_class.call(attempt: attempt, workspace_root: workspace_root, builder: builder)

      expect(result.digest).to eq("sha256:#{ 'a' * 64 }")
      expect(result.bundle_key).to eq(
        AppleVerification::ArtifactIngestion::Storage.bundle_key(
          account_id: account.id, project_id: project.id, attempt_id: attempt.id
        )
      )
      expect(result.bundle_url).to be_nil
    end
  end

  def build_stub_builder
    ->(workspace_root:, output_path:, manifest_path:) {
      File.binwrite(output_path, "tar-bytes")
      File.binwrite(manifest_path, JSON.generate({ "files" => [], "digest" => "sha256:#{ 'a' * 64 }" }))
      AppleVerification::SourceLane::BundleBuilder::Result.new(
        digest: "sha256:#{ 'a' * 64 }",
        bytesize: 9,
        manifest: { "files" => [], "digest" => "sha256:#{ 'a' * 64 }" },
        bundle_path: output_path,
        manifest_path: manifest_path
      )
    }
  end

  it "refuses to build a bundle for committed attempts" do
    committed = create(:apple_verification_attempt, :committed, project: project, account: account, apple_verification_workflow_revision: workflow)

    expect {
      described_class.call(attempt: committed, workspace_root: "/tmp/whatever")
    }.to raise_error(ArgumentError, /uncommitted/)
  end
end
