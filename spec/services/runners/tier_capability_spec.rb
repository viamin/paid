# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::TierCapability do
  let(:user) { create(:user) }
  # Materialized eagerly: creating the settings row validates the default
  # runner against the *unstubbed* executable runner keys.
  let!(:settings) { user.settings }

  describe ".supports_tier?" do
    it "is satisfiable for any runner when no tier is requested" do # @spec RUNNER-FALLBACK-001
      runner = user.runners.find_by!(runner_key: "claude")
      runner.update!(tier_models: {})

      expect(described_class.supports_tier?(runner, nil, user: user)).to be(true)
      expect(described_class.supports_tier?(runner, "", user: user)).to be(true)
    end

    it "supports the tier when the runner entry has an explicit tier_models entry" do
      runner = user.runners.find_by!(runner_key: "claude")
      runner.update!(tier_models: { "mid" => { "model_id" => "claude-sonnet-4-6", "provider_id" => runner.id } })

      expect(described_class.supports_tier?(runner, "mid", user: user)).to be(true)
      expect(described_class.supports_tier?(runner, "high", user: user)).to be(false)
    end

    it "supports every tier for a direct-outbound runner key even without a persisted entry" do
      expect(described_class.supports_tier?("opencode", "high", user: nil)).to be(true)
      expect(described_class.supports_tier?("kilocode", "mid", user: user)).to be(true)
    end

    it "supports every tier for a persisted direct-outbound runner" do
      runner = create(:runner, user: user, runner_key: "pi", config: { "pi" => { "model" => "MiniMax-M3" } })

      expect(described_class.supports_tier?(runner, "low", user: user)).to be(true)
    end

    it "does not treat a free-policy runner as direct-outbound" do
      runner = create(:runner, user: user, runner_key: "opencode")
      allow(runner).to receive(:free_model_policy?).and_return(true)

      expect(described_class.supports_tier?(runner, "high", user: user)).to be(false)
    end

    it "falls back to the catalog default for the runner key" do
      allow(Runners::DefaultTierModelIds).to receive(:call).and_return({ "mid" => "some-model" })

      expect(described_class.supports_tier?("claude", "mid", user: user)).to be(true)
      expect(described_class.supports_tier?("claude", "high", user: user)).to be(false)
    end

    it "falls back to the bound provider tier_models for a bare agent-type candidate" do
      provider = user.providers.find_by!(provider_key: "claude")
      provider.update!(tier_models: { "high" => { "model_id" => "claude-opus-4-1", "provider_id" => provider.id } })

      expect(described_class.supports_tier?("claude_code", "high", user: user)).to be(true)
      expect(described_class.supports_tier?("claude_code", "mid", user: user)).to be(false)
    end
  end

  describe ".any_supports_tier?" do
    it "is true when the tier is blank" do
      expect(described_class.any_supports_tier?([], nil, user: user)).to be(true)
    end

    it "is false when no candidate supports the tier" do
      low_only = { "low" => { "model_id" => "claude-haiku", "provider_id" => 1 } }
      claude = user.runners.find_by!(runner_key: "claude")
      claude.update!(tier_models: low_only)
      cursor = create(:runner, user: user, runner_key: "cursor", tier_models: low_only)

      expect(described_class.any_supports_tier?([ claude, cursor ], "high", user: user)).to be(false)
    end

    it "is true when at least one candidate supports the tier" do
      claude = user.runners.find_by!(runner_key: "claude")
      claude.update!(tier_models: { "low" => { "model_id" => "claude-haiku", "provider_id" => claude.id } })
      codex = create(:runner, user: user, runner_key: "codex",
        tier_models: { "high" => { "model_id" => "gpt-5", "provider_id" => 2 } })

      expect(described_class.any_supports_tier?([ claude, codex ], "high", user: user)).to be(true)
    end
  end

  describe ".dispatch_candidates" do # @spec RUNNER-FALLBACK-010
    let(:project) { create(:project, account: user.account, created_by: user) }

    before do
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[claude codex opencode])
    end

    it "uses the bound runner routing key plus configured fallbacks" do
      claude = user.runners.find_by!(runner_key: "claude")
      claude.update!(tier_models: { "mid" => { "model_id" => "claude-sonnet-4-6", "provider_id" => claude.id } })
      codex = create(:runner, user: user, runner_key: "codex",
        tier_models: { "mid" => { "model_id" => "gpt-5", "provider_id" => 2 } })
      agent_run = create(:agent_run, project: project, runner: claude, agent_type: "claude_code", goal: "create_pr")
      settings.update!(fallback_enabled: true, fallback_runners: [ codex.routing_key ])

      candidates = described_class.dispatch_candidates(agent_run: agent_run, user_settings: settings)

      expect(candidates).to eq([ claude.routing_key, codex.routing_key ])
    end

    it "uses the agent type plus fallbacks when no runner is bound" do
      codex = create(:runner, user: user, runner_key: "codex",
        tier_models: { "mid" => { "model_id" => "gpt-5", "provider_id" => 2 } })
      agent_run = create(:agent_run, project: project, agent_type: "claude_code", goal: "create_pr")
      settings.update!(fallback_enabled: true, fallback_runners: [ codex.routing_key ])

      candidates = described_class.dispatch_candidates(agent_run: agent_run, user_settings: settings)

      expect(candidates).to eq([ "claude_code", codex.routing_key ])
    end

    it "falls back to the first container-executable runner when the primary cannot run" do
      agent_run = create(:agent_run, project: project, agent_type: "claude_code", goal: "create_pr")
      allow(RunnerSupport).to receive(:container_executable_runner_keys).and_return(%w[codex])
      allow(RunnerSupport).to receive(:supported_runner_key?).with("claude").and_return(true)

      candidates = described_class.dispatch_candidates(agent_run: agent_run, user_settings: settings)

      expect(candidates).to eq([ "codex" ])
    end

    it "returns an empty list when nothing in the order can run in a container" do
      agent_run = create(:agent_run, project: project, agent_type: "claude_code", goal: "create_pr")
      allow(RunnerSupport).to receive_messages(
        container_executable_runner_keys: %w[codex],
        supported_runner_key?: false
      )

      candidates = described_class.dispatch_candidates(agent_run: agent_run, user_settings: settings)

      expect(candidates).to be_empty
    end
  end
end
