# frozen_string_literal: true

require "rails_helper"

RSpec.describe GithubInstallation do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:projects).dependent(:restrict_with_error) }
  end

  describe "validations" do
    subject { build(:github_installation) }

    it { is_expected.to validate_presence_of(:github_installation_id) }
    it { is_expected.to validate_uniqueness_of(:github_installation_id).scoped_to(:account_id) }
  end

  describe "scopes" do
    let(:account) { create(:account) }
    let!(:active_install) { create(:github_installation, account: account) }
    let!(:suspended_install) { create(:github_installation, account: account, suspended_at: Time.current) }
    let!(:revoked_install) { create(:github_installation, account: account, revoked_at: Time.current) }

    it ".active returns installations that are not suspended or revoked" do
      expect(described_class.active).to include(active_install)
      expect(described_class.active).not_to include(suspended_install)
      expect(described_class.active).not_to include(revoked_install)
    end

    it ".suspended returns suspended installations" do
      expect(described_class.suspended).to include(suspended_install)
      expect(described_class.suspended).not_to include(active_install)
    end

    it ".revoked returns revoked installations" do
      expect(described_class.revoked).to include(revoked_install)
      expect(described_class.revoked).not_to include(active_install)
    end
  end

  describe "#active?" do
    it "returns true when not suspended or revoked" do
      install = build(:github_installation)
      expect(install.active?).to be(true)
    end

    it "returns false when suspended" do
      install = build(:github_installation, suspended_at: Time.current)
      expect(install.active?).to be(false)
    end

    it "returns false when revoked" do
      install = build(:github_installation, revoked_at: Time.current)
      expect(install.active?).to be(false)
    end
  end

  describe "#covers_repository?" do
    it "returns true when the repository is explicitly accessible" do
      installation = build(:github_installation, accessible_repositories: [ { "full_name" => "acme/widgets" } ])

      expect(installation.covers_repository?("acme/widgets")).to be(true)
    end

    it "returns true for all-repo installations on the matching owner" do
      installation = build(:github_installation, :all_repos, account_login: "acme")

      expect(installation.covers_repository?("acme/widgets")).to be(true)
    end

    it "returns false when the installation is inactive" do
      installation = build(:github_installation, :revoked, accessible_repositories: [ { "full_name" => "acme/widgets" } ])

      expect(installation.covers_repository?("acme/widgets")).to be(false)
    end

    it "returns false when the repository is not covered" do
      installation = build(:github_installation, accessible_repositories: [ { "full_name" => "acme/other" } ])

      expect(installation.covers_repository?("acme/widgets")).to be(false)
    end
  end

  describe "#cached_repositories" do
    it "returns fresh cached repositories without checking app credentials" do
      installation = build(:github_installation, repositories_synced_at: 5.minutes.ago)

      expect(Github::AppRegistry).not_to receive(:configured?)

      expect(installation.cached_repositories).to eq(installation.accessible_repositories)
    end

    it "syncs stale repositories when app credentials are configured" do
      installation = create(:github_installation, repositories_synced_at: nil)
      repositories = [ { "id" => 456, "full_name" => "acme/refreshed" } ]

      allow(Github::AppRegistry).to receive(:configured?).and_return(true)
      allow(Github::InstallationRepositories).to receive(:fetch)
        .with(installation_id: installation.github_installation_id)
        .and_return(repositories)

      expect(installation.cached_repositories).to eq(repositories)
      expect(installation.reload.accessible_repositories).to eq(repositories)
      expect(installation.repositories_synced_at).to be_present
    end

    it "falls back to cached repositories when a stale sync fails" do
      installation = create(:github_installation, repositories_synced_at: nil)

      allow(Github::AppRegistry).to receive(:configured?).and_return(true)
      allow(Github::InstallationRepositories).to receive(:fetch)
        .and_raise(Github::InstallationRepositories::Error, "timeout")

      expect(installation.cached_repositories).to eq(installation.accessible_repositories)
      expect(installation.reload.repositories_synced_at).to be_nil
    end

    it "does not retry a failed sync until the failure backoff expires" do
      installation = create(:github_installation, repositories_synced_at: nil)

      allow(Github::AppRegistry).to receive(:configured?).and_return(true)
      allow(Github::InstallationRepositories).to receive(:fetch)
        .and_raise(Github::InstallationRepositories::Error, "timeout")

      with_memory_cache do
        installation.cached_repositories
        installation.cached_repositories
      end

      expect(Github::InstallationRepositories).to have_received(:fetch).once
    end
  end

  def with_memory_cache
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original_cache
  end
end
