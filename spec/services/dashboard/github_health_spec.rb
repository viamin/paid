# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::GithubHealth do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  describe ".call" do
    let(:account) { create(:account) }

    it "returns configured credential health for both App installations and PATs" do
      installation = create(:github_installation, account: account, account_login: "my-org")
      token = create(:github_token, account: account, name: "CI PAT")
      create(:project, account: account, github_token: token)
      create(:project, :with_github_installation, account: account, github_installation: installation)

      described_class.call(account: account).then do |stats|
        expect(stats).to include(
          total: 2,
          app_count: 1,
          pat_count: 1,
          rate_limited: 0,
          circuit_open: 0,
          has_github_credentials: true,
          healthy: true
        )
        labels = stats[:credentials].map(&:label)
        expect(labels).to include("my-org (Organization)")
        expect(labels).to include("CI PAT")
        expect(stats[:credentials].map(&:status)).to all(eq(:available))
      end
    end

    it "surfaces observed per-installation rate-limit usage on the dashboard" do
      installation = create(:github_installation, account: account)
      create(:project, :with_github_installation, account: account, github_installation: installation)
      create(
        :github_health_state,
        endpoint: GithubHealthState.endpoint_for_github_installation(installation.github_installation_id),
        rate_limit_remaining: 3000,
        rate_limit_limit: 15_000,
        rate_limit_reset_at: 1.hour.from_now,
        rate_limit_observed_at: 1.minute.ago
      )

      stats = described_class.call(account: account)

      install = stats[:credentials].find { |c| c.auth_source == "app" }
      expect(install.rate_limit_remaining).to eq(3000)
      expect(install.rate_limit_limit).to eq(15_000)
      expect(install.rate_limit_usage_percent).to eq(80.0)
    end

    it "flags rate-limited and circuit-open credentials as unhealthy" do
      installation = create(:github_installation, account: account)
      token = create(:github_token, account: account)
      create(:project, :with_github_installation, account: account, github_installation: installation)
      create(:project, account: account, github_token: token)
      create(
        :github_health_state, :rate_limited,
        endpoint: GithubHealthState.endpoint_for_github_installation(installation.github_installation_id)
      )
      create(
        :github_health_state, :circuit_open,
        endpoint: GithubHealthState.endpoint_for_github_token(token.id)
      )

      stats = described_class.call(account: account)

      expect(stats[:rate_limited]).to eq(1)
      expect(stats[:circuit_open]).to eq(1)
      expect(stats[:healthy]).to be false
    end

    it "scopes credentials to the current account so quotas do not collide cross-account" do
      installation = create(:github_installation, account: account)
      create(:project, :with_github_installation, account: account, github_installation: installation)

      other_account = create(:account)
      create(:github_installation, account: other_account)

      stats = described_class.call(account: account)

      expect(stats[:total]).to eq(1)
      expect(stats[:credentials].first.endpoint).to eq(
        GithubHealthState.endpoint_for_github_installation(installation.github_installation_id)
      )
    end

    it "reports no credentials when the account has none configured" do
      stats = described_class.call(account: account)

      expect(stats).to include(total: 0, has_github_credentials: false, healthy: true)
    end
  end
end
