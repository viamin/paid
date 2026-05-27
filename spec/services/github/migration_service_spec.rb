# frozen_string_literal: true

require "rails_helper"

RSpec.describe Github::MigrationService do
  describe ".migrate_from_token" do
    let(:account) { create(:account) }
    let(:actor) { create(:user, account: account) }
    let(:github_token) { create(:github_token, account: account, created_by: actor) }
    let(:installation) do
      create(
        :github_installation,
        account: account,
        accessible_repositories: [ { "id" => 101, "full_name" => "acme/accessible" } ]
      )
    end
    let!(:accessible_project) do
      create(
        :project,
        account: account,
        created_by: actor,
        github_token: github_token,
        github_id: 101
      )
    end
    let!(:inaccessible_project) do
      create(
        :project,
        account: account,
        created_by: actor,
        github_token: github_token,
        github_id: 202
      )
    end

    before do
      allow(Github::AppRegistry).to receive(:configured?).and_return(true)
      allow(Github::CacheInvalidator).to receive(:call)
      allow(Accounts::RecordActivity).to receive(:call)
    end

    it "reports successful and failed project counts" do
      result = described_class.migrate_from_token(
        github_token: github_token,
        github_installation: installation,
        actor: actor
      )

      expect(result.total).to eq(2)
      expect(result.successful).to eq(1)
      expect(result.failed).to eq(1)
      expect(result.results.map(&:project)).to contain_exactly(accessible_project, inaccessible_project)
      expect(result.results.find { |entry| entry.project == accessible_project }).to be_success

      failed_result = result.results.find { |entry| entry.project == inaccessible_project }
      expect(failed_result).not_to be_success
      expect(failed_result.error).to include("Installation does not have access to repository")
      expect(failed_result.warnings).to be_empty
    end

    it "fails every migration when the installation is inactive" do
      installation.update!(revoked_at: Time.current)

      result = described_class.migrate_from_token(
        github_token: github_token,
        github_installation: installation,
        actor: actor
      )

      expect(result.total).to eq(2)
      expect(result.successful).to eq(0)
      expect(result.failed).to eq(2)
      expect(result.results.map(&:error).uniq).to eq([ "GitHub App installation must be active" ])
    end
  end

  describe ".check_accessibility" do
    let(:account) { create(:account) }
    let(:github_token) { create(:github_token, account: account) }
    let(:installation) do
      create(
        :github_installation,
        account: account,
        accessible_repositories: [ { "id" => 1, "full_name" => "acme/accessible" } ]
      )
    end

    before do
      allow(Github::AppRegistry).to receive(:configured?).and_return(true)
      allow(github_token).to receive(:accessible_repositories).and_return(
        [
          { "id" => 1, "full_name" => "acme/accessible" },
          { "id" => 2, "full_name" => "acme/requires-admin" }
        ]
      )
    end

    it "indexes repositories by full name instead of scanning each time" do
      result = described_class.check_accessibility(
        github_token: github_token,
        github_installation: installation
      )

      expect(result).to eq(
        "acme/accessible" => :accessible,
        "acme/requires-admin" => :requires_admin_action
      )
    end

    it "rejects inactive tokens" do
      github_token.update!(revoked_at: Time.current)

      expect do
        described_class.check_accessibility(
          github_token: github_token,
          github_installation: installation
        )
      end.to raise_error(described_class::MigrationError, "GitHub token must be active")
    end
  end
end
