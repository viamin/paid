# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserSetting do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
  end

  describe "validations" do
    subject { build(:user_setting) }

    # Polling & Timing
    it { is_expected.to validate_numericality_of(:default_poll_interval_seconds).only_integer.is_greater_than_or_equal_to(60) }
    it { is_expected.to validate_numericality_of(:github_token_cache_ttl_minutes).only_integer.is_greater_than_or_equal_to(1) }
    it { is_expected.to validate_numericality_of(:token_validation_stale_minutes).only_integer.is_greater_than_or_equal_to(1) }

    # Agent Execution
    it { is_expected.to validate_numericality_of(:agent_timeout_seconds).only_integer.is_greater_than_or_equal_to(60) }
    it { is_expected.to validate_inclusion_of(:default_agent_provider).in_array(%w[claude cursor aider]) }

    # Container Resources
    it { is_expected.to validate_numericality_of(:container_memory_bytes).only_integer.is_greater_than_or_equal_to(512 * 1024 * 1024) }
    it { is_expected.to validate_numericality_of(:container_cpu_quota).only_integer.is_greater_than_or_equal_to(100_000) }
    it { is_expected.to validate_numericality_of(:container_timeout_seconds).only_integer.is_greater_than_or_equal_to(60) }

    # Project Defaults
    it { is_expected.to validate_presence_of(:default_branch) }

    # Retry & Resilience
    it { is_expected.to validate_numericality_of(:circuit_breaker_failure_threshold).only_integer.is_greater_than_or_equal_to(1) }
    it { is_expected.to validate_numericality_of(:circuit_breaker_timeout_seconds).only_integer.is_greater_than_or_equal_to(1) }
    it { is_expected.to validate_numericality_of(:retry_max_attempts).only_integer.is_greater_than_or_equal_to(1) }
    it { is_expected.to validate_numericality_of(:retry_base_delay).is_greater_than(0) }
    it { is_expected.to validate_numericality_of(:retry_max_delay).is_greater_than(0) }
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
      expect(setting.retry_max_attempts).to eq(3)
      expect(setting.retry_base_delay).to eq(1.0)
      expect(setting.retry_max_delay).to eq(60.0)
    end
  end
end
