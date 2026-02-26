# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserSetting do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    subject { build(:user_setting) }

    # Polling & Timing
    it { is_expected.to validate_numericality_of(:default_poll_interval_seconds).only_integer.is_greater_than_or_equal_to(60).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:github_token_cache_ttl_minutes).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:token_validation_stale_minutes).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }

    # Agent Execution
    it { is_expected.to validate_numericality_of(:agent_timeout_seconds).only_integer.is_greater_than_or_equal_to(60).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_inclusion_of(:default_agent_provider).in_array(%w[claude cursor aider]) }

    # Container Resources
    it { is_expected.to validate_numericality_of(:container_memory_bytes).only_integer.is_greater_than_or_equal_to(512 * 1024 * 1024).is_less_than_or_equal_to(described_class::MAX_CONTAINER_MEMORY_BYTES) }
    it { is_expected.to validate_numericality_of(:container_cpu_quota).only_integer.is_greater_than_or_equal_to(100_000).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:container_timeout_seconds).only_integer.is_greater_than_or_equal_to(60).is_less_than_or_equal_to(described_class::PG_INT_MAX) }

    # Project Defaults
    it { is_expected.to validate_presence_of(:default_branch) }

    # Retry & Resilience
    it { is_expected.to validate_numericality_of(:circuit_breaker_failure_threshold).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:circuit_breaker_timeout_seconds).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:retry_max_attempts).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:retry_base_delay).is_greater_than(0).is_less_than_or_equal_to(described_class::MAX_DELAY_SECONDS) }
    it { is_expected.to validate_numericality_of(:retry_max_delay).is_greater_than(0).is_less_than_or_equal_to(described_class::MAX_DELAY_SECONDS) }
  end

  describe ".enabled_agent_providers" do
    it "always includes claude" do
      expect(described_class.enabled_agent_providers).to include("claude")
    end

    it "includes cursor when CURSOR_ENABLED is true" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("CURSOR_ENABLED", "false").and_return("true")
      expect(described_class.enabled_agent_providers).to include("cursor")
    end

    it "excludes cursor when CURSOR_ENABLED is not true" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("CURSOR_ENABLED", "false").and_return("false")
      expect(described_class.enabled_agent_providers).not_to include("cursor")
    end

    it "includes aider when AIDER_ENABLED is true" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("AIDER_ENABLED", "false").and_return("true")
      expect(described_class.enabled_agent_providers).to include("aider")
    end

    it "excludes aider when AIDER_ENABLED is not true" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("AIDER_ENABLED", "false").and_return("false")
      expect(described_class.enabled_agent_providers).not_to include("aider")
    end
  end

  describe "#container_memory_gb" do
    it "converts bytes to gigabytes" do
      setting = build(:user_setting, container_memory_bytes: 4 * 1024 * 1024 * 1024)
      expect(setting.container_memory_gb).to eq(4.0)
    end
  end

  describe "#container_memory_gb=" do
    it "converts gigabytes to bytes" do
      setting = build(:user_setting)
      setting.container_memory_gb = 2
      expect(setting.container_memory_bytes).to eq(2 * 1024 * 1024 * 1024)
    end
  end

  describe "#container_cpus" do
    it "converts cpu_quota to CPU count" do
      setting = build(:user_setting, container_cpu_quota: 200_000)
      expect(setting.container_cpus).to eq(2)
    end
  end

  describe "#container_cpus=" do
    it "converts CPU count to cpu_quota" do
      setting = build(:user_setting)
      setting.container_cpus = 4
      expect(setting.container_cpu_quota).to eq(400_000)
    end
  end

  describe "#default_allowed_github_usernames_csv" do
    it "returns usernames as comma-separated string" do
      setting = build(:user_setting, default_allowed_github_usernames: %w[alice bob])
      expect(setting.default_allowed_github_usernames_csv).to eq("alice, bob")
    end

    it "returns empty string when no usernames" do
      setting = build(:user_setting, default_allowed_github_usernames: [])
      expect(setting.default_allowed_github_usernames_csv).to eq("")
    end
  end

  describe "#default_allowed_github_usernames_csv=" do
    it "parses comma-separated string into array" do
      setting = build(:user_setting)
      setting.default_allowed_github_usernames_csv = "alice, bob, charlie"
      expect(setting.default_allowed_github_usernames).to eq(%w[alice bob charlie])
    end

    it "strips whitespace and rejects blanks" do
      setting = build(:user_setting)
      setting.default_allowed_github_usernames_csv = " alice , , bob "
      expect(setting.default_allowed_github_usernames).to eq(%w[alice bob])
    end

    it "deduplicates usernames" do
      setting = build(:user_setting)
      setting.default_allowed_github_usernames_csv = "alice, bob, alice"
      expect(setting.default_allowed_github_usernames).to eq(%w[alice bob])
    end
  end

  describe "default values" do
    let(:user) { create(:user) }
    let(:setting) { described_class.create!(user: user) }

    it "sets default polling and timing values" do
      expect(setting.default_poll_interval_seconds).to eq(60)
      expect(setting.github_token_cache_ttl_minutes).to eq(60)
      expect(setting.token_validation_stale_minutes).to eq(2)
    end

    it "sets default agent execution values" do
      expect(setting.agent_timeout_seconds).to eq(3600)
      expect(setting.default_agent_provider).to eq("claude")
    end

    it "sets default container resource values" do
      expect(setting.container_memory_bytes).to eq(4 * 1024 * 1024 * 1024)
      expect(setting.container_cpu_quota).to eq(200_000)
      expect(setting.container_timeout_seconds).to eq(1800)
    end

    it "sets default project values" do
      expect(setting.default_branch).to eq("main")
      expect(setting.default_project_active).to be(true)
    end

    it "sets default retry and resilience values" do
      expect(setting.circuit_breaker_failure_threshold).to eq(5)
      expect(setting.circuit_breaker_timeout_seconds).to eq(300)
      expect(setting.retry_max_attempts).to eq(3)
      expect(setting.retry_base_delay).to eq(1.0)
      expect(setting.retry_max_delay).to eq(60.0)
    end

    it "sets default allowed github usernames" do
      expect(setting.default_allowed_github_usernames).to eq([])
    end
  end
end
