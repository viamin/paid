# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-TRANSFER-001
# @spec APPLE-TRANSFER-003
RSpec.describe AppleVerification::SourceLane::Build do
  let(:account) { create(:account) }
  let(:project) { create(:project, :with_github_installation, account: account) }
  let(:workflow_revision) { create(:apple_verification_workflow_revision, project: project, account: account) }
  let(:host_mount_check) { ->(_agent_run) { false } }

  around do |example|
    FeatureFlags.enable!(:apple_verification_workers, project: project)
    example.run
  ensure
    FeatureFlags.disable!(:apple_verification_workers, project: project)
  end

  context "with a committed attempt" do
    let(:attempt) { create(:apple_verification_attempt, :committed, apple_verification_workflow_revision: workflow_revision, project: project, account: account) }

    it "builds git and credentials lane entries and leaves object_storage empty" do
      result = described_class.call(attempt: attempt, host_mount_check: host_mount_check)

      expect(result.git).to include(
        "lane" => "git",
        "kind" => "repository_checkout",
        "locator" => hash_including("repo_full_name" => project.full_name, "commit_sha" => attempt.commit_sha)
      )
      expect(result.credentials.first["kind"]).to eq("github_app_installation")
      expect(result.object_storage).to eq([])
    end
  end

  context "with an uncommitted attempt" do
    let(:attempt) { create(:apple_verification_attempt, apple_verification_workflow_revision: workflow_revision, project: project, account: account) }

    it "builds an object-storage workspace bundle lane and leaves credentials empty" do
      result = described_class.call(attempt: attempt, host_mount_check: host_mount_check)

      expect(result.git.first["locator"]).not_to have_key("commit_sha")
      expect(result.git.first["locator"]).to include("bundle_digest" => attempt.source_digest)
      expect(result.credentials).to eq([])
      expect(result.object_storage.first["kind"]).to eq("workspace_bundle")
      expect(result.object_storage.first["locator"]).to include(
        "digest" => attempt.source_digest,
        "key" => AppleVerification::ArtifactIngestion::Storage.bundle_key(
          account_id: account.id, project_id: project.id, attempt_id: attempt.id
        )
      )
    end
  end

  context "when the rollout flag is disabled" do
    let(:attempt) { create(:apple_verification_attempt, :committed, apple_verification_workflow_revision: workflow_revision, project: project, account: account) }

    around do |example|
      FeatureFlags.disable!(:apple_verification_workers, project: project)
      example.run
    ensure
      FeatureFlags.disable!(:apple_verification_workers, project: project)
    end

    it "raises FeatureDisabledError without building any lane entry" do
      expect { described_class.call(attempt: attempt, host_mount_check: host_mount_check) }
        .to raise_error(AppleVerification::ExecuteGuestJob::FeatureDisabledError)
    end
  end

  context "when the originating paid-agent container has a write host mount" do
    let(:agent_run) { create(:agent_run, project: project) }
    let(:attempt) { create(:apple_verification_attempt, :committed, apple_verification_workflow_revision: workflow_revision, project: project, account: account, agent_run: agent_run) }

    it "raises HostMountPresentError" do
      expect { described_class.call(attempt: attempt, host_mount_check: ->(_run) { true }) }
        .to raise_error(described_class::HostMountPresentError)
    end

    it "proceeds when the host mount check returns false" do
      expect { described_class.call(attempt: attempt, host_mount_check: ->(_run) { false }) }
        .not_to raise_error
    end
  end

  context "when the uncommitted attempt has no source digest" do
    let(:attempt) { create(:apple_verification_attempt, apple_verification_workflow_revision: workflow_revision, project: project, account: account) }

    it "raises BundlesNotSupportedError" do
      allow(attempt).to receive(:source_digest).and_return(nil)
      expect { described_class.call(attempt: attempt, host_mount_check: host_mount_check) }
        .to raise_error(described_class::BundlesNotSupportedError)
    end
  end

  context "when host_mount_check is missing" do
    let(:attempt) { create(:apple_verification_attempt, :committed, apple_verification_workflow_revision: workflow_revision, project: project, account: account) }

    it "raises ArgumentError so the guard fails closed" do
      expect { described_class.call(attempt: attempt) }
        .to raise_error(ArgumentError)
    end
  end
end
