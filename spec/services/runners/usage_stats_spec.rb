# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::UsageStats do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }

  describe ".call" do
    subject(:stats) { described_class.call(user: user) }

    context "with no agent runs" do
      it "returns an empty hash" do
        expect(stats).to eq({})
      end
    end

    context "with agent runs and token usages" do
      before do
        run = create(:agent_run, :completed, project: project, agent_type: "claude_code",
          cost_cents: 50, tokens_input: 1000, tokens_output: 500, created_at: 2.days.ago,
          runners_attempted: [
            { "provider" => "claude", "success" => true, "duration_seconds" => 42.5 }
          ])
        create(:token_usage, agent_run: run, cost_cents: 50,
          input_tokens: 1000, output_tokens: 500, created_at: 2.days.ago)
      end

      it "aggregates run counts by effective provider" do
        expect(stats["claude"][:runs_7d]).to eq(1)
      end

      it "aggregates cost from token usages" do
        expect(stats["claude"][:cost_cents_7d]).to eq(50)
      end

      it "aggregates tokens from token usages" do
        expect(stats["claude"][:tokens_7d]).to eq(1500)
      end

      it "returns zero fallback rate when no fallbacks occurred" do
        expect(stats["claude"][:fallback_rate]).to eq(0.0)
        expect(stats["claude"][:fallback_total]).to eq(1)
        expect(stats["claude"][:fallback_switched]).to eq(0)
      end

      it "returns zero rate limit events when none occurred" do
        expect(stats["claude"][:rate_limit_events_7d]).to eq(0)
      end

      it "includes attempt-level success and duration metrics" do
        expect(stats["claude"]).to include(
          attempts_7d: 1,
          success_attempts_7d: 1,
          success_rate_7d: 100.0,
          timeout_events_7d: 0,
          error_events_7d: 0,
          avg_attempt_duration_seconds: 42.5
        )
      end
    end

    context "with fallback runs" do
      before do
        create(:agent_run, :completed, project: project, agent_type: "claude_code",
          final_runner: "codex", runner_switches: 1, created_at: 3.days.ago)
      end

      it "computes fallback rate for the requested provider" do
        expect(stats["claude"][:fallback_rate]).to eq(100.0)
        expect(stats["claude"][:fallback_switched]).to eq(1)
        expect(stats["claude"][:fallback_total]).to eq(1)
      end

      it "counts the run under the effective provider" do
        expect(stats["codex"][:runs_7d]).to eq(1)
      end
    end

    context "with rate-limited runs" do
      before do
        create(:agent_run, project: project, agent_type: "claude_code",
          status: "rate_limited", created_at: 1.day.ago,
          runners_attempted: [
            { "provider" => "claude", "success" => false, "error_type" => "rate_limited", "duration_seconds" => 90.0 }
          ])
      end

      it "counts rate limit events" do
        expect(stats["claude"][:rate_limit_events_7d]).to eq(1)
      end
    end

    context "with attempt metrics stored under an agent-type alias" do
      before do
        create(:agent_run, :failed, project: project, agent_type: "claude_code", created_at: 1.day.ago,
          runners_attempted: [
            { "provider" => "claude_code", "success" => false, "error_type" => "timeout", "duration_seconds" => 900.0 },
            { "provider" => "claude_code", "success" => true, "duration_seconds" => 30.0 }
          ])
      end

      it "normalizes attempt metrics to the provider key" do
        expect(stats["claude"]).to include(
          attempts_7d: 2,
          success_attempts_7d: 1,
          success_rate_7d: 50.0,
          timeout_events_7d: 1,
          rate_limit_events_7d: 0,
          error_events_7d: 0,
          avg_attempt_duration_seconds: 465.0
        )
      end
    end

    context "with timeout and error attempts for a routed provider entry" do
      let(:owner) { project.effective_owner }
      let(:api_key) { create(:provider_api_key, user: owner, api_service_type: "zai_coding") }
      let!(:provider) do
        create(:runner, :api_key, user: owner, runner_key: "kilocode",
          provider_api_key: api_key, name: "Kilocode GLM 5.1",
          config: { "kilocode" => { "api_provider" => "zai_coding", "model" => "glm-5.1" } })
      end

      before do
        create(:agent_run, :failed, project: project, agent_type: "kilocode", created_at: 1.day.ago,
          runners_attempted: [
            { "provider" => provider.routing_key, "success" => false, "error_type" => "timeout", "duration_seconds" => 900.0 },
            { "provider" => provider.routing_key, "success" => false, "error_type" => "error", "duration_seconds" => 30.0 }
          ])
      end

      it "aggregates attempt-level failure metrics by provider identifier" do
        expect(stats[provider.routing_key]).to include(
          attempts_7d: 2,
          success_attempts_7d: 0,
          success_rate_7d: 0.0,
          timeout_events_7d: 1,
          rate_limit_events_7d: 0,
          error_events_7d: 1,
          avg_attempt_duration_seconds: 465.0
        )
      end
    end

    context "with status-based rate-limited runs missing runners_attempted data" do
      before do
        create(:agent_run, project: project, agent_type: "claude_code",
          status: "rate_limited", created_at: 1.day.ago,
          runners_attempted: [])
      end

      it "counts rate limit events from run status as fallback" do
        expect(stats["claude"][:rate_limit_events_7d]).to eq(1)
      end
    end

    context "with runs outside the 7-day window" do
      before do
        create(:agent_run, :completed, project: project, agent_type: "claude_code",
          created_at: 10.days.ago)
      end

      it "excludes old runs from counts" do
        expect(stats).to eq({})
      end
    end

    context "with runs from another account" do
      before do
        other_account = create(:account)
        other_project = create(:project, account: other_account)
        create(:agent_run, :completed, project: other_project, agent_type: "claude_code",
          created_at: 1.day.ago)
      end

      it "does not include other account's runs" do
        expect(stats).to eq({})
      end
    end

    context "with no token usages for a provider" do
      before do
        create(:agent_run, :completed, project: project, agent_type: "claude_code",
          created_at: 2.days.ago)
      end

      it "shows zero cost and tokens when no token usages exist" do
        expect(stats["claude"][:cost_cents_7d]).to eq(0)
        expect(stats["claude"][:tokens_7d]).to eq(0)
      end
    end

    context "with cached results" do
      around do |example|
        original_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
        example.run
      ensure
        Rails.cache = original_cache
      end

      it "returns cached data on subsequent calls" do
        create(:agent_run, :completed, project: project, agent_type: "claude_code",
          created_at: 1.day.ago)

        first_result = described_class.call(user: user)
        expect(first_result["claude"][:runs_7d]).to eq(1)

        create(:agent_run, :completed, project: project, agent_type: "claude_code",
          created_at: 1.day.ago)

        cached_result = described_class.call(user: user)
        expect(cached_result["claude"][:runs_7d]).to eq(1)
      end
    end
  end
end
