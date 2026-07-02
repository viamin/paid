# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserSetting do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to have_many(:runner_states).through(:user) }
  end

  describe "legacy provider aliases" do
    let(:user) { create(:user) }
    let(:goal_runner_identifier) { user.runners.kept_only.for_agent_runs.ordered.first.routing_key }

    let(:runner_backed_setting) do
      create(
        :user_setting,
        user: user,
        default_agent_runner: "cursor",
        default_agent_runners_by_goal: { "review" => goal_runner_identifier },
        fallback_runners: [ "claude", "cursor" ],
        runner_selection_mode: "round_robin",
        runner_round_robin_state: { "review" => 1 },
        kb_chat_runner: "cursor",
        kb_chat_fallback_runners: [ "claude" ],
        kb_embedding_runner: "openrouter",
        kb_embedding_fallback_runners: [ "openai" ]
      )
    end

    it "exposes runner-named settings through legacy provider aliases" do
      expect(runner_backed_setting.default_agent_provider).to eq("claude")
      expect(runner_backed_setting.default_agent_providers_by_goal).to eq({ "review" => goal_runner_identifier })
      expect(runner_backed_setting.fallback_providers).to eq([ "claude" ])
      expect(runner_backed_setting.provider_selection_mode).to eq("round_robin")
      expect(runner_backed_setting.provider_round_robin_state).to eq({ "review" => 1 })
      expect(runner_backed_setting.kb_chat_provider).to eq("cursor")
      expect(runner_backed_setting.kb_chat_fallback_providers).to eq([ "claude" ])
      expect(runner_backed_setting.kb_embedding_provider).to eq("openrouter")
      expect(runner_backed_setting.kb_embedding_fallback_providers).to eq([ "openai" ])
    end

    it "updates runner-named settings when legacy provider setters are used" do
      setting = build(:user_setting, user: user)

      setting.default_agent_provider = "cursor"
      setting.default_agent_providers_by_goal = { "review" => goal_runner_identifier }
      setting.fallback_providers = [ "claude", "cursor" ]
      setting.provider_selection_mode = "round_robin"
      setting.provider_round_robin_state = { "review" => 1 }
      setting.kb_chat_provider = "cursor"
      setting.kb_chat_fallback_providers = [ "claude" ]
      setting.kb_embedding_provider = "openrouter"
      setting.kb_embedding_fallback_providers = [ "openai" ]

      expect(setting.default_agent_runner).to eq("cursor")
      expect(setting.default_agent_runners_by_goal).to eq({ "review" => goal_runner_identifier })
      expect(setting.fallback_runners).to eq([ "claude", "cursor" ])
      expect(setting.runner_selection_mode).to eq("round_robin")
      expect(setting.runner_round_robin_state).to eq({ "review" => 1 })
      expect(setting.kb_chat_runner).to eq("cursor")
      expect(setting.kb_chat_fallback_runners).to eq([ "claude" ])
      expect(setting.kb_embedding_runner).to eq("openrouter")
      expect(setting.kb_embedding_fallback_runners).to eq([ "openai" ])
    end
  end

  describe "validations" do
    subject { build(:user_setting) }

    # Polling & Timing
    it { is_expected.to validate_numericality_of(:default_poll_interval_seconds).only_integer.is_greater_than_or_equal_to(60).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:github_token_cache_ttl_minutes).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:token_validation_stale_minutes).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }

    # Agent Execution
    it { is_expected.to validate_numericality_of(:agent_timeout_seconds).only_integer.is_greater_than_or_equal_to(60).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_inclusion_of(:agent_update_comment_mode).in_array(described_class::AGENT_UPDATE_COMMENT_MODES) }

    it "validates default_agent_runner against enabled runners" do
      setting = build(:user_setting, default_agent_runner: "invalid")

      expect(setting).to be_valid
      expect(setting.default_agent_runner).to eq("claude")
    end

    # Container Resources
    it { is_expected.to validate_numericality_of(:container_memory_bytes).only_integer.is_greater_than_or_equal_to(512 * 1024 * 1024).is_less_than_or_equal_to(described_class::MAX_CONTAINER_MEMORY_BYTES) }
    # Token & rate limits
    it { is_expected.to validate_numericality_of(:max_tokens_per_run).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    # Goal-specific timeouts
    it { is_expected.to validate_numericality_of(:issue_goal_timeout_seconds).only_integer.is_greater_than_or_equal_to(30).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:issue_goal_idle_timeout_seconds).only_integer.is_greater_than_or_equal_to(30).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:review_goal_idle_timeout_seconds).only_integer.is_greater_than_or_equal_to(30).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:create_pr_idle_timeout_seconds).only_integer.is_greater_than_or_equal_to(30).is_less_than_or_equal_to(described_class::PG_INT_MAX).allow_nil }
    # Max execution time override
    it { is_expected.to validate_numericality_of(:max_execution_seconds).only_integer.is_greater_than_or_equal_to(60).is_less_than_or_equal_to(86_400).allow_nil }
    # Git operation timeouts
    it { is_expected.to validate_numericality_of(:git_clone_timeout_seconds).only_integer.is_greater_than_or_equal_to(30).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:git_push_timeout_seconds).only_integer.is_greater_than_or_equal_to(10).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    # Prompt building limits
    it { is_expected.to validate_numericality_of(:max_prompt_comments).only_integer.is_greater_than_or_equal_to(0).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:max_comment_length).only_integer.is_greater_than_or_equal_to(100).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    # Style guide byte limits
    it { is_expected.to validate_numericality_of(:style_guide_max_raw_bytes).only_integer.is_greater_than_or_equal_to(1000).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:style_guide_max_total_bytes).only_integer.is_greater_than_or_equal_to(1000).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:style_guide_max_raw_prompt_bytes).only_integer.is_greater_than_or_equal_to(1000).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    # Concurrency
    it { is_expected.to validate_inclusion_of(:run_concurrency_mode).in_array(described_class::RUN_CONCURRENCY_MODES) }
    it { is_expected.to validate_numericality_of(:max_concurrent_runs).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(100).allow_nil }
    it { is_expected.to validate_numericality_of(:max_parallel_agents_per_project).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(20) }
    it { is_expected.to validate_numericality_of(:max_auto_pick_open_prs).only_integer.is_greater_than_or_equal_to(0).is_less_than_or_equal_to(100) }
    it { is_expected.to validate_numericality_of(:container_timeout_seconds).only_integer.is_greater_than_or_equal_to(60).is_less_than_or_equal_to(described_class::PG_INT_MAX) }

    it "requires max_concurrent_runs in manual mode" do
      setting = build(:user_setting, run_concurrency_mode: "manual", max_concurrent_runs: nil)

      expect(setting).not_to be_valid
      expect(setting.errors[:max_concurrent_runs]).to include("must be set in manual run concurrency mode")
    end

    it "allows max_concurrent_runs to be blank in auto mode" do
      setting = build(:user_setting, run_concurrency_mode: "auto", max_concurrent_runs: nil)

      expect(setting).to be_valid
    end

    # Project Defaults
    it { is_expected.to validate_presence_of(:default_branch) }

    # Retry & Resilience
    it { is_expected.to validate_numericality_of(:circuit_breaker_failure_threshold).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:circuit_breaker_timeout_seconds).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:retry_max_attempts).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(described_class::PG_INT_MAX) }
    it { is_expected.to validate_numericality_of(:retry_base_delay).is_greater_than(0).is_less_than_or_equal_to(described_class::MAX_DELAY_SECONDS) }
    it { is_expected.to validate_numericality_of(:retry_max_delay).is_greater_than(0).is_less_than_or_equal_to(described_class::MAX_DELAY_SECONDS) }
  end

  describe ".enabled_agent_runners" do
    let(:user) { create(:user) }

    it "returns user-configured run-enabled runners filtered to container-executable" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor])
      user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true)
      user.runners.create!(runner_key: "aider", enabled_for_agent_runs: true)

      expect(described_class.enabled_agent_runners(user)).to contain_exactly("claude", "cursor")
    end

    it "excludes non-container-executable runners even when enabled for agent runs" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude])
      user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true)

      expect(described_class.enabled_agent_runners(user)).to eq([ "claude" ])
    end

    it "returns claude when no user is provided" do
      expect(described_class.enabled_agent_runners).to eq([ "claude" ])
    end

    it "returns an empty list when no user is provided and claude is not container-executable" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[cursor])

      expect(described_class.enabled_agent_runners).to eq([])
    end

    it "filters out stale runners that are no longer container-executable" do
      user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true)

      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude])

      expect(described_class.enabled_agent_runners(user)).to eq([ "claude" ])
    end
  end

  describe ".fallback_candidate_providers" do
    let(:user) { create(:user) }

    it "returns configured fallback runners filtered to container-executable" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor])
      user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: false, enabled_for_fallback: true)
      user.runners.create!(runner_key: "aider", enabled_for_agent_runs: false, enabled_for_fallback: true)

      expect(described_class.fallback_candidate_providers(user)).to contain_exactly("claude", "cursor")
    end

    it "returns an empty list when no user is provided and claude is not container-executable" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[cursor])

      expect(described_class.fallback_candidate_providers(nil)).to eq([])
    end

    it "filters out stale fallback runners that are no longer container-executable" do
      user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: false, enabled_for_fallback: true)

      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude])

      expect(described_class.fallback_candidate_providers(user)).to eq([ "claude" ])
    end
  end

  describe ".rate_limit_fallback_runners" do
    let(:user) { create(:user) }

    it "returns canonical runner keys for configured rate-limit fallbacks" do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude])
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      user.runners.create!(
        runner_key: "claude",
        auth_type: "api_key",
        provider_api_key: api_key,
        fallback_role: "rate_limit_fallback",
        enabled_for_agent_runs: true,
        enabled_for_fallback: true
      )

      expect(described_class.rate_limit_fallback_runners(user)).to eq([ "claude" ])
    end
  end

  describe "goal-specific default runners" do
    let(:user) { create(:user) }

    before do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor codex])
    end

    it "normalizes configured goal defaults to runner identifiers" do
      cursor = user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true)
      setting = build(
        :user_setting,
        user: user,
        default_agent_runners_by_goal: {
          "create_pr" => "cursor",
          "review" => "claude",
          "create_issue" => ""
        }
      )

      expect(setting).to be_valid
      expect(setting.default_agent_runners_by_goal).to eq(
        "create_pr" => cursor.routing_key,
        "review" => user.runners.find_by!(runner_key: "claude").routing_key
      )
    end

    it "canonicalizes legacy provider goal defaults to runner identifiers" do
      codex = user.runners.create!(runner_key: "codex", enabled_for_agent_runs: true)
      setting = build(
        :user_setting,
        user: user,
        default_agent_runners_by_goal: { "review" => codex.legacy_routing_key }
      )

      expect(setting).to be_valid
      expect(setting.default_agent_runners_by_goal).to eq("review" => codex.routing_key)
    end

    it "falls back to the global default when no goal-specific runner is set" do
      codex = user.runners.create!(runner_key: "codex", enabled_for_agent_runs: true)
      setting = create(:user_setting, user: user, default_agent_runner: codex.routing_key)

      expect(setting.default_provider_identifier_for_goal("review")).to eq(codex.routing_key)
    end

    it "uses the goal-specific runner ahead of the global default" do
      cursor = user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      codex = user.runners.create!(runner_key: "codex", enabled_for_agent_runs: true, enabled_for_fallback: true)
      setting = create(
        :user_setting,
        user: user,
        default_agent_runner: cursor.routing_key,
        default_agent_runners_by_goal: { "review" => codex.routing_key },
        fallback_enabled: true
      )

      expect(setting.default_provider_identifier_for_goal("review")).to eq(codex.routing_key)
      expect(setting.provider_priority_for_goal("review", identifiers: true).first).to eq(codex.routing_key)
    end

    it "wraps fallback order around a goal-specific runner lower in the configured list" do
      cursor = user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      codex = user.runners.create!(runner_key: "codex", enabled_for_agent_runs: true, enabled_for_fallback: true)
      setting = create(
        :user_setting,
        user: user,
        default_agent_runner: user.runners.find_by!(runner_key: "claude").routing_key,
        default_agent_runners_by_goal: { "review" => codex.routing_key },
        fallback_enabled: true,
        fallback_runners: [
          user.runners.find_by!(runner_key: "claude").routing_key,
          cursor.routing_key,
          codex.routing_key
        ]
      )

      expect(setting.provider_priority_for_goal("review", identifiers: true)).to eq(
        [ codex.routing_key, user.runners.find_by!(runner_key: "claude").routing_key, cursor.routing_key ]
      )
    end

    it "canonicalizes a legacy provider default runner to the runner identifier" do
      codex = user.runners.create!(runner_key: "codex", enabled_for_agent_runs: true)
      setting = build(:user_setting, user: user, default_agent_runner: codex.legacy_routing_key)

      expect(setting).to be_valid
      expect(setting.default_agent_runner).to eq(codex.routing_key)
    end

    it "rejects invalid goals" do
      setting = build(:user_setting, user: user, default_agent_runners_by_goal: { "ship_it" => "claude" })

      expect(setting).not_to be_valid
      expect(setting.errors[:default_agent_runners_by_goal]).to include("contains invalid goal: ship_it")
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

  describe "#auto_pick_skip_labels_csv" do
    it "returns labels as a comma-separated string" do
      setting = build(:user_setting, auto_pick_skip_labels: %w[planning research])

      expect(setting.auto_pick_skip_labels_csv).to eq("planning, research")
    end

    it "returns an empty string when labels are not configured" do
      setting = build(:user_setting, auto_pick_skip_labels: nil)

      expect(setting.auto_pick_skip_labels_csv).to eq("")
    end
  end

  describe "#auto_pick_skip_labels_csv=" do
    it "parses comma-separated labels into a deduplicated array" do
      setting = build(:user_setting)
      setting.auto_pick_skip_labels_csv = " planning, research, planning "

      expect(setting.auto_pick_skip_labels).to eq(%w[planning research])
    end

    it "normalizes labels to lowercase before deduplicating" do
      setting = build(:user_setting)
      setting.auto_pick_skip_labels_csv = " Planning, research, PLANNING "

      expect(setting.auto_pick_skip_labels).to eq(%w[planning research])
    end

    it "allows configuring an empty skip-label list" do
      setting = build(:user_setting)
      setting.auto_pick_skip_labels_csv = ""

      expect(setting.auto_pick_skip_labels).to eq([])
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
      expect(setting.agent_timeout_seconds).to eq(5400)
      expect(setting.default_agent_runner).to eq(user.runners.find_by!(runner_key: "claude").routing_key)
    end

    it "sets default container resource values" do
      expect(setting.container_memory_bytes).to eq(4 * 1024 * 1024 * 1024)
      expect(setting.container_timeout_seconds).to eq(3600)
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

    it "sets default knowledge runner values" do
      expect(setting.kb_embedding_runner).to eq("openai")
      expect(setting.kb_embedding_fallback_runners).to eq([])
      expect(setting.kb_chat_runner).to eq("claude")
      expect(setting.kb_chat_fallback_runners).to eq([])
    end
  end

  describe "#provider_priority" do
    let(:user) { create(:user) }

    before do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor aider])
      user.runners.create!(runner_key: "cursor")
      user.runners.create!(runner_key: "aider")
    end

    it "returns default runner first, then fallbacks" do
      setting = build(:user_setting, user: user, default_agent_runner: "claude", fallback_runners: %w[cursor aider])
      expect(setting.provider_priority).to eq(%w[claude cursor aider])
    end

    it "excludes the default runner from fallback list" do
      setting = build(:user_setting, user: user, default_agent_runner: "claude", fallback_runners: %w[claude cursor])
      expect(setting.provider_priority).to eq(%w[claude cursor aider])
    end

    it "handles empty fallback_runners" do
      setting = build(:user_setting, user: user, default_agent_runner: "claude", fallback_runners: [])
      expect(setting.provider_priority).to eq(%w[claude aider cursor])
    end

    it "handles nil fallback_runners" do
      setting = build(:user_setting, user: user, default_agent_runner: "claude")
      setting.fallback_runners = nil
      expect(setting.provider_priority).to eq(%w[claude aider cursor])
    end

    it "appends configured fallback runners missing from saved order" do
      setting = build(:user_setting, user: user, default_agent_runner: "claude", fallback_runners: [ "cursor" ])

      expect(setting.provider_priority).to eq(%w[claude cursor aider])
    end

    it "includes fallback-only runners in the runtime priority" do
      user.runners.find_by!(runner_key: "cursor").update!(
        enabled_for_agent_runs: false,
        enabled_for_fallback: true
      )

      setting = build(:user_setting, user: user, default_agent_runner: "claude", fallback_runners: [])

      expect(setting.provider_priority).to eq(%w[claude aider cursor])
    end
  end

  describe "#select_automated_provider_identifier" do
    let(:user) { create(:user) }
    let(:claude) { user.runners.find_by!(runner_key: "claude") }
    let!(:cursor) { user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true) }
    let!(:aider) { user.runners.create!(runner_key: "aider", enabled_for_agent_runs: true) }
    let(:settings) { user.settings }

    before do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor aider])
    end

    it "returns the goal-specific default in single mode" do
      settings.update!(runner_selection_mode: "single", default_agent_runner: claude.routing_key)
      expect(settings.select_automated_provider_identifier).to eq(claude.routing_key)
    end

    it "returns the only enabled runner when fewer than two are enabled" do
      cursor.update!(enabled_for_agent_runs: false)
      aider.update!(enabled_for_agent_runs: false)
      settings.update!(runner_selection_mode: "round_robin")

      expect(settings.select_automated_provider_identifier).to eq(claude.routing_key)
    end

    describe "round_robin mode" do
      it "cycles through runners in alphabetical-key order, repeating each weight times" do
        # Providers iterate in `ordered` scope (provider_key ASC):
        # aider, claude, cursor.
        aider.update!(weight: 1)
        claude.update!(weight: 3)
        cursor.update!(weight: 1)
        settings.update!(runner_selection_mode: "round_robin")

        sequence = Array.new(10) { settings.select_automated_provider_identifier }
        expected_cycle = [
          aider.routing_key,
          claude.routing_key, claude.routing_key, claude.routing_key,
          cursor.routing_key
        ]
        expect(sequence).to eq(expected_cycle + expected_cycle)
      end

      it "resets the cursor when runner weights change" do
        aider.update!(weight: 5)
        settings.update!(runner_selection_mode: "round_robin")

        2.times { settings.select_automated_provider_identifier }
        aider.update!(weight: 1)

        first_after_change = settings.select_automated_provider_identifier
        expect(first_after_change).to eq(aider.routing_key)
      end
    end

    describe "random mode" do
      it "respects weights when picking a runner" do
        # Ordered candidates: aider (1), claude (3), cursor (1)
        # Cumulative weights: aider [0..0], claude [1..3], cursor [4..4]
        aider.update!(weight: 1)
        claude.update!(weight: 3)
        cursor.update!(weight: 1)
        settings.update!(runner_selection_mode: "random")

        allow(SecureRandom).to receive(:random_number).with(5).and_return(0, 1, 3, 4)

        results = Array.new(4) { settings.select_automated_provider_identifier }
        expect(results).to eq([ aider.routing_key, claude.routing_key, claude.routing_key, cursor.routing_key ])
      end
    end
  end

  describe "#fallback_priority_for" do
    let(:user) { create(:user) }

    before do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor aider])
      user.runners.create!(runner_key: "cursor")
      user.runners.create!(runner_key: "aider")
    end

    it "respects saved order before appending remaining configured runners" do
      setting = build(:user_setting, user: user, fallback_runners: [ "aider" ])

      expect(setting.fallback_priority_for(primary_provider: "claude")).to eq(%w[aider cursor])
    end

    it "wraps configured order after the current primary runner" do
      setting = build(:user_setting, user: user, fallback_runners: %w[claude cursor aider])

      expect(setting.fallback_priority_for(primary_provider: "cursor")).to eq(%w[aider claude])
    end
  end

  describe "#available_providers" do
    let(:user) { create(:user) }
    let(:setting) { create(:user_setting, user: user, fallback_runners: %w[cursor aider]) }

    before do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor aider])
      user.runners.create!(runner_key: "cursor")
      user.runners.create!(runner_key: "aider")
    end

    it "returns all runners when none are unavailable" do
      expect(setting.available_providers).to eq(%w[claude cursor aider])
    end

    it "excludes rate-limited runners" do
      create(:runner_state, user: user, runner_name: "cursor", rate_limited_until: 1.hour.from_now)
      expect(setting.available_providers).to eq(%w[claude aider])
    end

    it "excludes runners with open circuits" do
      create(:runner_state, :circuit_open, user: user, runner_name: "claude")
      expect(setting.available_providers).to eq(%w[cursor aider])
    end

    it "includes runners with half-open circuits" do
      create(:runner_state, :circuit_half_open, user: user, runner_name: "cursor")
      expect(setting.available_providers).to eq(%w[claude cursor aider])
    end
  end

  describe "#provider_state_for" do
    let(:user) { create(:user) }
    let(:setting) { create(:user_setting, user: user) }

    it "creates a new runner state if one does not exist" do
      state = setting.provider_state_for("claude")
      expect(state).to be_persisted
      expect(state.runner_name).to eq("claude")
    end

    it "returns the existing runner state" do
      existing = create(:runner_state, user: user, runner_name: "claude")
      state = setting.provider_state_for("claude")
      expect(state.id).to eq(existing.id)
    end

    it "handles concurrent creation races by finding the created row" do
      relation = user.runner_states
      existing = create(:runner_state, user: user, runner_name: "claude")

      allow(relation).to receive(:find_or_create_by!)
        .with(runner_name: "claude")
        .and_raise(ActiveRecord::RecordNotUnique)
      allow(relation).to receive(:find_by!)
        .with(runner_name: "claude")
        .and_return(existing)

      state = setting.provider_state_for("claude")

      expect(state.id).to eq(existing.id)
    end
  end

  describe "#validate_fallback_runners" do
    let(:user) { create(:user) }

    before do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor aider])
    end

    it "is valid with known runners" do
      user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      setting = build(:user_setting, user: user, fallback_runners: %w[claude cursor])
      expect(setting).to be_valid
    end

    it "accepts runners that are fallback-only" do
      cursor = user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: false, enabled_for_fallback: true)
      setting = build(:user_setting, user: user, fallback_runners: %w[claude cursor])

      expect(setting).to be_valid
      expect(setting.fallback_runners).to eq([ user.runners.find_by!(runner_key: "claude").routing_key, cursor.routing_key ])
    end

    it "sanitizes unknown runners" do
      setting = build(:user_setting, user: user, fallback_runners: %w[claude unknown_provider])
      expect(setting).to be_valid
      expect(setting.fallback_runners).to eq([ user.runners.find_by!(runner_key: "claude").routing_key ])
    end

    it "is valid with empty array" do
      setting = build(:user_setting, user: user, fallback_runners: [])
      expect(setting).to be_valid
    end

    it "is invalid with non-array value" do
      setting = build(:user_setting, user: user)
      setting.fallback_runners = "not_an_array"
      expect(setting).not_to be_valid
      expect(setting.errors[:fallback_runners]).to include("must be an array")
    end
  end

  describe "knowledge base runner settings" do
    let(:setting) { build(:user_setting) }

    it "normalizes blank primary runners to defaults" do
      setting.kb_embedding_runner = " "
      setting.kb_chat_runner = nil

      expect(setting).to be_valid
      expect(setting.kb_embedding_runner).to eq("openai")
      expect(setting.kb_chat_runner).to eq("claude")
    end

    it "normalizes and deduplicates knowledge fallback runners" do
      setting.kb_embedding_fallback_runners = [ " OpenAI ", "", "openai", "DeepSeek" ]
      setting.kb_chat_fallback_runners = [ " Claude ", "cursor", "cursor" ]

      expect(setting).to be_valid
      expect(setting.kb_embedding_fallback_runners).to eq(%w[openai deepseek])
      expect(setting.kb_chat_fallback_runners).to eq(%w[claude cursor])
    end

    it "rejects unsupported knowledge embedding runners" do
      setting.kb_embedding_runner = "anthropic"
      setting.kb_embedding_fallback_runners = [ "openai", "also-not-a-runner" ]

      expect(setting).not_to be_valid
      expect(setting.errors[:kb_embedding_runner]).to include("is not a supported knowledge embedding runner")
      expect(setting.errors[:kb_embedding_fallback_runners]).to include("contains unsupported runners: also-not-a-runner")
    end

    it "rejects unsupported knowledge chat runners" do
      setting.kb_chat_runner = "not-a-runner"
      setting.kb_chat_fallback_runners = [ "claude", "also-invalid" ]

      expect(setting).not_to be_valid
      expect(setting.errors[:kb_chat_runner]).to include("is not a supported knowledge chat runner")
      expect(setting.errors[:kb_chat_fallback_runners]).to include("contains unsupported runners: also-invalid")
    end

    it "rejects non-array knowledge fallback runner values" do
      setting.kb_embedding_fallback_runners = "not_an_array"
      setting.kb_chat_fallback_runners = {}

      expect(setting).not_to be_valid
      expect(setting.errors[:kb_embedding_fallback_runners]).to include("must be an array")
      expect(setting.errors[:kb_chat_fallback_runners]).to include("must be an array")
    end
  end

  describe "runner token normalization" do
    let(:user) { create(:user) }
    let(:setting) { build(:user_setting, user: user) }

    before do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor aider])
    end

    it "resolves runner-key tokens without calling Runner.for_identifier per candidate" do
      cursor = user.runners.create!(runner_key: "cursor", enabled_for_agent_runs: true, enabled_for_fallback: true)
      aider = user.runners.create!(runner_key: "aider", enabled_for_agent_runs: true, enabled_for_fallback: true)

      expect(Runner).not_to receive(:for_identifier)

      result = setting.send(:identifiers_for_provider_token, "cursor", candidates: [ cursor.routing_key, aider.routing_key ])

      expect(result).to eq([ cursor.routing_key ])
    end

    it "prefers the subscription entry when multiple entries share a runner key" do
      subscription = user.runners.find_by!(runner_key: "claude")
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      api_entry = user.runners.create!(
        runner_key: "claude",
        auth_type: "api_key",
        provider_api_key: api_key,
        enabled_for_agent_runs: true,
        enabled_for_fallback: true
      )

      result = setting.send(
        :identifiers_for_provider_token,
        "claude",
        candidates: [ api_entry.routing_key, subscription.routing_key ]
      )

      expect(result).to eq([ subscription.routing_key ])
    end

    it "uses candidate order to deterministically choose among api-key entries" do
      first_entry = create_cursor_api_entry("First Cursor")
      second_entry = create_cursor_api_entry("Second Cursor")

      result = setting.send(
        :identifiers_for_provider_token,
        "cursor",
        candidates: [ second_entry.routing_key, first_entry.routing_key ]
      )

      expect(result).to eq([ second_entry.routing_key ])
    end

    def create_cursor_api_entry(name)
      user.runners.create!(
        runner_key: "cursor",
        auth_type: "api_key",
        provider_api_key: create(:provider_api_key, user: user, api_service_type: "anthropic"),
        name: name,
        enabled_for_agent_runs: true,
        enabled_for_fallback: true
      )
    end
  end

  describe "new-record runner availability" do
    before do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude cursor aider])
    end

    it "uses the new user when resolving agent-run runners" do
      new_user = build(:user)
      setting = build(:user_setting, user: new_user)

      expect(setting.send(:allowed_runner_identifiers_for_agent_runs)).to match_array(%w[claude cursor aider])
    end

    it "uses the new user when resolving fallback runners" do
      new_user = build(:user)
      setting = build(:user_setting, user: new_user)

      expect(setting.send(:allowed_runner_identifiers_for_fallback)).to match_array(%w[claude cursor aider])
    end
  end
end
