# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserSetting do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to have_many(:provider_states).through(:user) }
  end

  describe "validations" do
    subject { build(:user_setting) }

    # Polling & Timing
    it { is_expected.to validate_numericality_of(:default_poll_interval_seconds).only_integer.is_greater_than_or_equal_to(60).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:github_token_cache_ttl_minutes).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:token_validation_stale_minutes).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }

    # Agent Execution
    it { is_expected.to validate_numericality_of(:agent_timeout_seconds).only_integer.is_greater_than_or_equal_to(60).is_less_than_or_equal_to(described_class::PG_INT_MAX) }

    it "validates default_agent_provider against enabled providers" do
      setting = build(:user_setting, default_agent_provider: "invalid")

      expect(setting).to be_valid
      expect(setting.default_agent_provider).to eq("claude")
    end

    # Container Resources
    it { is_expected.to validate_numericality_of(:container_memory_bytes).only_integer.is_greater_than_or_equal_to(512 * 1024 * 1024).is_less_than_or_equal_to(described_class::MAX_CONTAINER_MEMORY_BYTES) }
    # Concurrency
    it { is_expected.to validate_numericality_of(:max_concurrent_runs).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(100) }
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
    let(:user) { create(:user) }

    it "returns user-configured run-enabled providers" do
      user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true)
      user.providers.create!(provider_key: "aider", enabled_for_agent_runs: false)

      expect(described_class.enabled_agent_providers(user)).to contain_exactly("claude", "cursor")
    end

    it "returns claude when no user is provided" do
      expect(described_class.enabled_agent_providers).to eq([ "claude" ])
    end
  end

  describe ".fallback_candidate_providers" do
    let(:user) { create(:user) }

    it "returns configured fallback providers even when not enabled for agent runs" do
      user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: false, enabled_for_fallback: true)
      user.providers.create!(provider_key: "aider", enabled_for_agent_runs: false, enabled_for_fallback: false)

      expect(described_class.fallback_candidate_providers(user)).to contain_exactly("claude", "cursor")
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

  describe "#allowed_service_images_csv" do
    it "returns images as comma-separated string" do
      setting = build(:user_setting, allowed_service_images: [ "postgres:16", "redis:7-alpine" ])
      expect(setting.allowed_service_images_csv).to eq("postgres:16, redis:7-alpine")
    end

    it "returns empty string when no images" do
      setting = build(:user_setting, allowed_service_images: [])
      expect(setting.allowed_service_images_csv).to eq("")
    end
  end

  describe "#allowed_service_images_csv=" do
    it "parses comma-separated string into array" do
      setting = build(:user_setting)
      setting.allowed_service_images_csv = "postgres:16, redis:7-alpine, selenium/standalone-chrome:latest"
      expect(setting.allowed_service_images).to eq([ "postgres:16", "redis:7-alpine", "selenium/standalone-chrome:latest" ])
    end

    it "strips whitespace and rejects blanks" do
      setting = build(:user_setting)
      setting.allowed_service_images_csv = " postgres:16 , , redis:7-alpine "
      expect(setting.allowed_service_images).to eq([ "postgres:16", "redis:7-alpine" ])
    end

    it "deduplicates images" do
      setting = build(:user_setting)
      setting.allowed_service_images_csv = "postgres:16, redis:7-alpine, postgres:16"
      expect(setting.allowed_service_images).to eq([ "postgres:16", "redis:7-alpine" ])
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
      expect(setting.container_timeout_seconds).to eq(1800)
    end

    it "sets default concurrency values" do
      expect(setting.max_concurrent_runs).to eq(2)
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

  describe "#provider_priority" do
    let(:user) { create(:user) }

    before do
      user.providers.create!(provider_key: "cursor")
      user.providers.create!(provider_key: "aider")
    end

    it "returns default provider first, then fallbacks" do
      setting = build(:user_setting, user: user, default_agent_provider: "claude", fallback_providers: %w[cursor aider])
      expect(setting.provider_priority).to eq(%w[claude cursor aider])
    end

    it "excludes the default provider from fallback list" do
      setting = build(:user_setting, user: user, default_agent_provider: "claude", fallback_providers: %w[claude cursor])
      expect(setting.provider_priority).to eq(%w[claude cursor aider])
    end

    it "handles empty fallback_providers" do
      setting = build(:user_setting, user: user, default_agent_provider: "claude", fallback_providers: [])
      expect(setting.provider_priority).to eq(%w[claude aider cursor])
    end

    it "handles nil fallback_providers" do
      setting = build(:user_setting, user: user, default_agent_provider: "claude")
      setting.fallback_providers = nil
      expect(setting.provider_priority).to eq(%w[claude aider cursor])
    end

    it "appends configured fallback providers missing from saved order" do
      setting = build(:user_setting, user: user, default_agent_provider: "claude", fallback_providers: [ "cursor" ])

      expect(setting.provider_priority).to eq(%w[claude cursor aider])
    end

    it "includes fallback-only providers in the runtime priority" do
      user.providers.find_by!(provider_key: "cursor").update!(
        enabled_for_agent_runs: false,
        enabled_for_fallback: true
      )

      setting = build(:user_setting, user: user, default_agent_provider: "claude", fallback_providers: [])

      expect(setting.provider_priority).to eq(%w[claude aider cursor])
    end
  end

  describe "#fallback_priority_for" do
    let(:user) { create(:user) }

    before do
      user.providers.create!(provider_key: "cursor")
      user.providers.create!(provider_key: "aider")
    end

    it "respects saved order before appending remaining configured providers" do
      setting = build(:user_setting, user: user, fallback_providers: [ "aider" ])

      expect(setting.fallback_priority_for(primary_provider: "claude")).to eq(%w[aider cursor])
    end

    it "excludes the current primary provider from fallback order" do
      setting = build(:user_setting, user: user, fallback_providers: %w[claude cursor aider])

      expect(setting.fallback_priority_for(primary_provider: "cursor")).to eq(%w[claude aider])
    end
  end

  describe "#available_providers" do
    let(:user) { create(:user) }
    let(:setting) { create(:user_setting, user: user, fallback_providers: %w[cursor aider]) }

    before do
      user.providers.create!(provider_key: "cursor")
      user.providers.create!(provider_key: "aider")
    end

    it "returns all providers when none are unavailable" do
      expect(setting.available_providers).to eq(%w[claude cursor aider])
    end

    it "excludes rate-limited providers" do
      create(:provider_state, user: user, provider_name: "cursor", rate_limited_until: 1.hour.from_now)
      expect(setting.available_providers).to eq(%w[claude aider])
    end

    it "excludes providers with open circuits" do
      create(:provider_state, :circuit_open, user: user, provider_name: "claude")
      expect(setting.available_providers).to eq(%w[cursor aider])
    end

    it "includes providers with half-open circuits" do
      create(:provider_state, :circuit_half_open, user: user, provider_name: "cursor")
      expect(setting.available_providers).to eq(%w[claude cursor aider])
    end
  end

  describe "#provider_state_for" do
    let(:user) { create(:user) }
    let(:setting) { create(:user_setting, user: user) }

    it "creates a new provider state if one does not exist" do
      state = setting.provider_state_for("claude")
      expect(state).to be_persisted
      expect(state.provider_name).to eq("claude")
    end

    it "returns the existing provider state" do
      existing = create(:provider_state, user: user, provider_name: "claude")
      state = setting.provider_state_for("claude")
      expect(state.id).to eq(existing.id)
    end

    it "handles concurrent creation races by finding the created row" do
      relation = user.provider_states
      existing = create(:provider_state, user: user, provider_name: "claude")

      allow(relation).to receive(:find_or_create_by!)
        .with(provider_name: "claude")
        .and_raise(ActiveRecord::RecordNotUnique)
      allow(relation).to receive(:find_by!)
        .with(provider_name: "claude")
        .and_return(existing)

      state = setting.provider_state_for("claude")

      expect(state.id).to eq(existing.id)
    end
  end

  describe "#validate_fallback_providers" do
    let(:user) { create(:user) }

    it "is valid with known providers" do
      user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      setting = build(:user_setting, user: user, fallback_providers: %w[claude cursor])
      expect(setting).to be_valid
    end

    it "accepts providers that are fallback-only" do
      user.providers.create!(provider_key: "cursor", enabled_for_agent_runs: false, enabled_for_fallback: true)
      setting = build(:user_setting, user: user, fallback_providers: %w[claude cursor])

      expect(setting).to be_valid
      expect(setting.fallback_providers).to eq(%w[claude cursor])
    end

    it "sanitizes unknown providers" do
      setting = build(:user_setting, user: user, fallback_providers: %w[claude unknown_provider])
      expect(setting).to be_valid
      expect(setting.fallback_providers).to eq([ "claude" ])
    end

    it "is valid with empty array" do
      setting = build(:user_setting, user: user, fallback_providers: [])
      expect(setting).to be_valid
    end

    it "is invalid with non-array value" do
      setting = build(:user_setting, user: user)
      setting.fallback_providers = "not_an_array"
      expect(setting).not_to be_valid
      expect(setting.errors[:fallback_providers]).to include("must be an array")
    end
  end
end
