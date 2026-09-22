# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-TRANSFER-001
RSpec.describe AppleVerification::SourceLane::CredentialLane do
  let(:account) { create(:account) }
  let(:project) { create(:project, :with_github_installation, account: account) }
  let(:workflow_revision) { create(:apple_verification_workflow_revision, project: project, account: account) }
  let(:attempt) { create(:apple_verification_attempt, :committed, apple_verification_workflow_revision: workflow_revision, project: project, account: account) }

  describe ".call" do
    context "with a committed attempt and an active installation" do
      it "returns a reference describing the installation and its TTL" do
        result = described_class.call(attempt: attempt)

        expect(result.installation_id).to eq(project.github_installation.github_installation_id)
        expect(result.repository_id).to eq(project.github_id)
        expect(result.repo_full_name).to eq(project.full_name)
        expect(result.ttl_seconds).to be > 0
      end

      it "renders a credentials lane entry without the resolved token value" do
        result = described_class.call(attempt: attempt)
        entry = described_class.lane_entry(result)

        expect(entry).to include(
          "lane" => "credentials",
          "kind" => "github_app_installation"
        )
        expect(entry["locator"]).not_to have_key("token")
        expect(entry["locator"]).not_to have_key("value")
        expect(entry["locator"]).not_to have_key("secret")
        expect(entry.dig("locator", "installation_id")).to eq(result.installation_id)
      end
    end

    context "with an uncommitted attempt" do
      let(:attempt) { create(:apple_verification_attempt, apple_verification_workflow_revision: workflow_revision, project: project, account: account) }

      it "raises MissingCommitError" do
        expect { described_class.call(attempt: attempt) }
          .to raise_error(described_class::MissingCommitError)
      end
    end

    context "when the project has no installation" do
      let(:project) { create(:project, account: account) }
      let(:attempt) { create(:apple_verification_attempt, :committed, apple_verification_workflow_revision: workflow_revision, project: project, account: account) }

      it "raises InstallationUnavailableError" do
        expect { described_class.call(attempt: attempt) }
          .to raise_error(described_class::InstallationUnavailableError)
      end
    end

    context "when the installation is suspended" do
      before { project.github_installation.update!(suspended_at: Time.current) }

      it "raises InvalidInstallationError" do
        expect { described_class.call(attempt: attempt) }
          .to raise_error(described_class::InvalidInstallationError, /suspended/)
      end
    end

    context "when the installation is revoked" do
      before { project.github_installation.update!(revoked_at: Time.current) }

      it "raises InvalidInstallationError" do
        expect { described_class.call(attempt: attempt) }
          .to raise_error(described_class::InvalidInstallationError, /revoked/)
      end
    end

    context "when the installation does not cover the project's repository" do
      before do
        project.github_installation.update!(
          accessible_repositories: [ { "full_name" => "different/repo", "id" => 123 } ],
          repository_selection: "selected"
        )
      end

      it "raises InvalidInstallationError" do
        expect { described_class.call(attempt: attempt) }
          .to raise_error(described_class::InvalidInstallationError, /does not cover/)
      end
    end
  end

  describe "#mint_token! and #revoke!" do
    let(:installation) { project.github_installation }
    let(:cache_key) { "apple_verification_credential_token:#{installation.github_installation_id}:#{attempt.id}" }
    let(:provider_instance) { instance_double(Github::AppInstallation, mint: "ghs_attempt_scoped_token", revoke: nil) }
    let(:provider) { class_double(Github::AppInstallation) }

    before do
      allow(provider).to receive(:new).with(
        installation_id: installation.github_installation_id,
        repo_full_name: project.full_name
      ).and_return(provider_instance)
    end

    describe "#mint_token!" do
      it "mints a dedicated per-attempt token instead of using the shared project-wide cache" do
        token = described_class.new(attempt: attempt, token_provider: provider).mint_token!

        expect(token).to eq("ghs_attempt_scoped_token")
        expect(provider).to have_received(:new).with(
          installation_id: installation.github_installation_id,
          repo_full_name: project.full_name
        )
        expect(provider_instance).to have_received(:mint)
      end

      it "caches the minted token under an attempt-scoped key so a later revoke reads the same value" do
        allow(Rails.cache).to receive(:fetch).with(cache_key, expires_in: described_class::DEFAULT_TTL_SECONDS).and_yield
        described_class.new(attempt: attempt, token_provider: provider).mint_token!

        expect(Rails.cache).to have_received(:fetch).with(cache_key, expires_in: described_class::DEFAULT_TTL_SECONDS)
      end
    end

    describe "#revoke!" do
      it "revokes only the attempt-scoped token and clears the attempt-scoped cache entry" do
        allow(Rails.cache).to receive(:read).with(cache_key).and_return("ghs_attempt_scoped_token")
        allow(Rails.cache).to receive(:delete).with(cache_key)

        described_class.new(attempt: attempt, token_provider: provider).revoke!

        expect(provider_instance).to have_received(:revoke).with("ghs_attempt_scoped_token")
        expect(Rails.cache).to have_received(:delete).with(cache_key)
      end

      it "never touches Github::AppInstallation's shared project-wide cache or revoke_token" do
        allow(Rails.cache).to receive(:read).with(cache_key).and_return("ghs_attempt_scoped_token")
        allow(Rails.cache).to receive(:delete).with(cache_key)
        allow(Github::AppInstallation).to receive(:revoke_token)

        described_class.new(attempt: attempt, token_provider: provider).revoke!

        expect(Github::AppInstallation).not_to have_received(:revoke_token)
      end

      it "is a no-op when no token was ever minted for this attempt" do
        allow(Rails.cache).to receive(:read).with(cache_key).and_return(nil)
        allow(Rails.cache).to receive(:delete).with(cache_key)

        described_class.new(attempt: attempt, token_provider: provider).revoke!

        expect(provider_instance).not_to have_received(:revoke)
        expect(Rails.cache).to have_received(:delete).with(cache_key)
      end

      it "is a no-op when the attempt has no commit_sha" do
        uncommitted = create(:apple_verification_attempt, apple_verification_workflow_revision: workflow_revision, project: project, account: account)
        described_class.new(attempt: uncommitted, token_provider: provider).revoke!
        expect(provider).not_to have_received(:new)
      end

      it "swallows GitHub API errors so the audit trail is still recorded, and still clears the cache entry" do
        allow(Rails.cache).to receive(:read).with(cache_key).and_return("ghs_attempt_scoped_token")
        allow(Rails.cache).to receive(:delete).with(cache_key)
        allow(provider_instance).to receive(:revoke).and_raise(Github::AppInstallation::Error, "boom")

        expect {
          described_class.new(attempt: attempt, token_provider: provider).revoke!
        }.not_to raise_error

        expect(Rails.cache).to have_received(:delete).with(cache_key)
      end
    end
  end
end
