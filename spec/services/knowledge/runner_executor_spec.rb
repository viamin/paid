# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::RunnerExecutor do
  let(:user) { create(:user) }
  let(:user_setting) { user.settings }
  let(:project) { create(:project, account: user.account) }
  let(:knowledge_run) { create(:knowledge_run, project: project) }

  before do
    allow(Knowledge::RunnerSelector).to receive(:for_chat)
      .with(user_setting: user_setting)
      .and_return(%w[claude openai])
    allow(Knowledge::RunnerSelector).to receive(:for_embedding)
      .with(user_setting: user_setting)
      .and_return(%w[openai])
  end

  describe "#execute" do
    it "calls the block with the first available runner on success" do
      executor = described_class.new(user_setting: user_setting, operation: :chat)

      result = executor.execute { |runner| "response from #{runner}" }

      expect(result).to eq("response from claude")
    end

    it "falls back to next runner on RateLimitError" do
      executor = described_class.new(user_setting: user_setting, operation: :chat)
      call_count = 0

      result = executor.execute do |runner|
        call_count += 1
        raise AgentHarness::RateLimitError, "rate limited" if runner == "claude"
        "response from #{runner}"
      end

      expect(result).to eq("response from openai")
      expect(call_count).to eq(2)
    end

    it "falls back to next runner on generic AgentHarness::Error" do
      executor = described_class.new(user_setting: user_setting, operation: :chat)

      result = executor.execute do |runner|
        raise AgentHarness::Error, "runner error" if runner == "claude"
        "response from #{runner}"
      end

      expect(result).to eq("response from openai")
    end

    it "raises AllRunnersExhausted when all runners fail" do
      executor = described_class.new(user_setting: user_setting, operation: :chat)

      expect {
        executor.execute { |_runner| raise AgentHarness::Error, "failed" }
      }.to raise_error(
        Knowledge::RunnerExecutor::AllRunnersExhausted,
        /All runners exhausted for chat/
      )
    end

    it "raises AllRunnersExhausted when no runners available" do
      allow(Knowledge::RunnerSelector).to receive(:for_embedding).and_return([])

      executor = described_class.new(user_setting: user_setting, operation: :embedding)

      expect {
        executor.execute { |_runner| "result" }
      }.to raise_error(
        Knowledge::RunnerExecutor::AllRunnersExhausted,
        /No available runners/
      )
    end

    context "with knowledge_run tracking" do
      it "records runner attempts on the knowledge run" do
        executor = described_class.new(
          user_setting: user_setting,
          operation: :chat,
          knowledge_run: knowledge_run
        )

        executor.execute { |_runner| "ok" }

        knowledge_run.reload
        expect(knowledge_run.runner_attempts.size).to eq(1)
        expect(knowledge_run.runner_attempts.first["runner"]).to eq("claude")
      end

      it "records final_runner on success" do
        executor = described_class.new(
          user_setting: user_setting,
          operation: :chat,
          knowledge_run: knowledge_run
        )

        executor.execute { |_runner| "ok" }

        knowledge_run.reload
        expect(knowledge_run.final_runner).to eq("claude")
      end

      it "records multiple attempts on fallback" do
        executor = described_class.new(
          user_setting: user_setting,
          operation: :chat,
          knowledge_run: knowledge_run
        )

        executor.execute do |runner|
          raise AgentHarness::Error, "fail" if runner == "claude"
          "ok"
        end

        knowledge_run.reload
        expect(knowledge_run.runner_attempts.size).to eq(2)
        expect(knowledge_run.final_runner).to eq("openai")
      end
    end

    context "with RunnerState updates" do
      it "records success on RunnerState" do
        executor = described_class.new(user_setting: user_setting, operation: :chat)
        executor.execute { |_runner| "ok" }

        state = user.runner_states.find_by(runner_name: "claude")
        expect(state).to be_present
        expect(state.circuit_state).to eq("closed")
        expect(state.failure_count).to eq(0)
      end

      it "marks runner as rate limited on RateLimitError" do
        executor = described_class.new(user_setting: user_setting, operation: :chat)

        executor.execute do |runner|
          raise AgentHarness::RateLimitError, "rate limited" if runner == "claude"
          "ok"
        end

        state = user.runner_states.find_by(runner_name: "claude")
        expect(state).to be_present
        expect(state.rate_limited?).to be true
      end

      it "records failure on RunnerState for generic errors" do
        executor = described_class.new(user_setting: user_setting, operation: :chat)

        executor.execute do |runner|
          raise AgentHarness::Error, "error" if runner == "claude"
          "ok"
        end

        state = user.runner_states.find_by(runner_name: "claude")
        expect(state).to be_present
        expect(state.failure_count).to eq(1)
      end

      it "decays prior failures using the configured circuit breaker timeout" do
        user_setting.update!(circuit_breaker_timeout_seconds: 600)
        # Stale count of 4; 400s elapsed is < one 600s decay window, so nothing
        # ages out before the new failure increments to 5. With the default
        # 300s window it would decay one window (4 >> 1 = 2) and land at 3.
        user.runner_states.create!(runner_name: "claude", circuit_state: "closed",
          failure_count: 4, last_failure_at: 400.seconds.ago)

        executor = described_class.new(user_setting: user_setting, operation: :chat)
        executor.execute do |runner|
          raise AgentHarness::Error, "error" if runner == "claude"
          "ok"
        end

        expect(user.runner_states.find_by(runner_name: "claude").failure_count).to eq(5)
      end
    end

    context "with structured logging" do
      it "logs runner switches when falling back" do
        allow(Rails.logger).to receive(:warn)
        executor = described_class.new(
          user_setting: user_setting,
          operation: :chat,
          knowledge_run: knowledge_run
        )

        executor.execute do |runner|
          raise AgentHarness::RateLimitError, "rate limited" if runner == "claude"
          "ok"
        end

        expect(Rails.logger).to have_received(:warn).with(hash_including(
          message: "knowledge.runner_switch",
          from_runner: "claude",
          to_runner: "openai",
          operation: "chat",
          knowledge_run_id: knowledge_run.id
        ))
      end

      it "logs when all runners are unavailable before execution starts" do
        allow(Rails.logger).to receive(:warn)
        allow(Knowledge::RunnerSelector).to receive(:for_chat)
          .with(user_setting: user_setting)
          .and_return([])

        executor = described_class.new(user_setting: user_setting, operation: :chat)

        expect {
          executor.execute { |_runner| "ok" }
        }.to raise_error(Knowledge::RunnerExecutor::AllRunnersExhausted)

        expect(Rails.logger).to have_received(:warn).with(hash_including(
          message: "knowledge.runners_unavailable",
          operation: "chat",
          reason: "no_available_runners"
        ))
      end
    end

    context "with free-policy rotation" do
      let!(:free_model_high) { create(:llm_model, :free, model_id: "free-high-current", tier: "high", capability_score: 7.0) }
      let(:free_model_high_alt) { create(:llm_model, :free, model_id: "free-high-other", tier: "high", capability_score: 5.0) }
      let!(:free_model_mid) { create(:llm_model, :free, model_id: "free-mid", tier: "mid", capability_score: 4.0) }
      let(:api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }
      let(:openrouter_runner) do
        user.runners.create!(
          runner_key: "opencode",
          auth_type: "api_key",
          provider_api_key: api_key,
          enabled_for_chat: false,
          config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } },
          tier_model_ids: {
            "high" => free_model_high.model_id,
            "mid" => free_model_mid.model_id,
            "low" => free_model_mid.model_id
          }
        )
      end

      before do
        free_model_high_alt
        allow(Knowledge::RunnerSelector).to receive(:for_chat)
          .with(user_setting: user_setting)
          .and_return([ "opencode", "openai" ])
        openrouter_runner # ensure created
      end

      it "retries with the rotated model after a rate-limit error" do
        executor = described_class.new(user_setting: user_setting, operation: :chat)
        attempt = 0

        result = executor.execute do |runner|
          attempt += 1
          if runner == "opencode" && attempt == 1
            raise AgentHarness::RateLimitError, "rate limited"
          end

          "response from #{runner}"
        end

        expect(result).to eq("response from opencode")
        expect(attempt).to eq(2)
        # The rotated model succeeded and fully recovered the runner, so the
        # original user-configured model is restored (no permanent drift).
        expect(openrouter_runner.reload.tier_model_ids["high"]).to eq(free_model_high.model_id)
      end

      it "restores the original tier_model_ids after a successful rotated call" do
        executor = described_class.new(user_setting: user_setting, operation: :chat)
        attempt = 0

        executor.execute do |runner|
          attempt += 1
          raise AgentHarness::RateLimitError, "rate limited" if attempt == 1

          "ok"
        end

        runner_state = user.runner_states.find_by(runner_name: openrouter_runner.state_key)
        # Recovery snapshot is cleared once restored so a later run does not
        # revert a user's manual edit.
        expect(runner_state.preferred_tier_model_ids).to be_nil
        expect(openrouter_runner.reload.tier_model_ids).to eq(
          "high" => free_model_high.model_id,
          "mid" => free_model_mid.model_id,
          "low" => free_model_mid.model_id
        )
      end

      it "does not restore tier_model_ids when the runner does not fully recover" do
        # An open circuit blocks the full reset in record_success!, so the
        # rotated tier_model_ids must stay in place until recovery completes.
        runner_state = user.runner_states.create!(
          runner_name: openrouter_runner.state_key,
          circuit_state: "open",
          circuit_opened_at: 1.minute.ago,
          failure_count: 5
        )
        runner_state.record_preferred_tier_model_ids!("high" => free_model_high.model_id)

        executor = described_class.new(user_setting: user_setting, operation: :chat)
        attempt = 0

        executor.execute do |runner|
          attempt += 1
          raise AgentHarness::RateLimitError, "rate limited" if attempt == 1

          "ok"
        end

        # Rotation still happened, but the open circuit prevented recovery, so
        # the rotated model stays and the snapshot is preserved.
        expect(openrouter_runner.reload.tier_model_ids["high"]).to eq(free_model_high_alt.model_id)
        expect(runner_state.reload.preferred_tier_model_ids).to eq("high" => free_model_high.model_id)
      end

      it "falls through to the next runner when the rotated model also rate-limits" do
        executor = described_class.new(user_setting: user_setting, operation: :chat)
        openrouter_attempts = 0

        result = executor.execute do |runner|
          if runner == "opencode"
            openrouter_attempts += 1
            raise AgentHarness::RateLimitError, "rate limited" if openrouter_attempts <= 2
          end
          "response from #{runner}"
        end

        # Both high-tier models were tried and rate-limited before rotation
        # exhausted, so the runner fails over to the next one in the chain.
        expect(result).to eq("response from openai")
        expect(openrouter_attempts).to eq(2)
        expect(openrouter_runner.reload.tier_model_ids["high"]).to eq(free_model_high_alt.model_id)

        state = user.runner_states.find_by(runner_name: openrouter_runner.state_key)
        expect(state.rate_limited_model_ids).to include(free_model_high.model_id, free_model_high_alt.model_id)
      end

      it "falls through to the next runner when rotation is exhausted" do
        allow(FreeModels::Rotation).to receive(:call).and_return(
          FreeModels::Rotation::Result.new(rotated: false, exhausted: true, runner: openrouter_runner,
            model_id: nil, previous_model_id: nil, tier: nil)
        )

        executor = described_class.new(user_setting: user_setting, operation: :chat)

        result = executor.execute do |runner|
          raise AgentHarness::RateLimitError, "rate limited" if runner == "opencode"
          "response from #{runner}"
        end

        expect(result).to eq("response from openai")
      end

      it "records the rate-limited model in RunnerState metadata on rate-limit error" do
        executor = described_class.new(user_setting: user_setting, operation: :chat)

        executor.execute do |runner|
          raise AgentHarness::RateLimitError, "rate limited" if runner == "opencode"
          "ok"
        end

        state = user.runner_states.find_by(runner_name: openrouter_runner.state_key)
        expect(state).to be_present
        expect(state.rate_limited_model_ids).to include(free_model_high.model_id)
        expect(state.rate_limited_until).to be_present
      end

      it "resolves free-policy RunnerState onto the runner's routing key, not the bare runner_key" do
        # opencode is not single-instance (a user may hold several free-policy
        # opencode runners, one per OpenRouter credential), so state must be
        # disambiguated by routing key rather than the shared "opencode"
        # runner_key string.
        executor = described_class.new(user_setting: user_setting, operation: :chat)

        executor.execute do |runner|
          raise AgentHarness::Error, "error" if runner == "opencode"
          "ok"
        end

        expect(user.runner_states.where(runner_name: "opencode")).not_to exist
        state = user.runner_states.find_by(runner_name: openrouter_runner.state_key)
        expect(state).to be_present
        expect(state.failure_count).to eq(1)
      end
    end

    context "with opencode free-policy rotation" do
      let!(:free_model_high) { create(:llm_model, :free, model_id: "free-high-current", tier: "high", capability_score: 7.0) }
      let!(:free_model_high_alt) { create(:llm_model, :free, model_id: "free-high-other", tier: "high", capability_score: 5.0) }
      let!(:free_model_mid) { create(:llm_model, :free, model_id: "free-mid", tier: "mid", capability_score: 4.0) }
      let(:api_key) { create(:provider_api_key, user: user, api_service_type: "openrouter") }
      let(:free_policy_runner) do
        user.runners.create!(
          runner_key: "opencode",
          auth_type: "api_key",
          provider_api_key: api_key,
          enabled_for_chat: false,
          config: { "opencode" => { "api_provider" => "openrouter", "model_policy" => "free" } },
          tier_model_ids: {
            "high" => free_model_high.model_id,
            "mid" => free_model_mid.model_id,
            "low" => free_model_mid.model_id
          }
        )
      end

      before do
        free_model_high_alt
        free_policy_runner # ensure created
        # RunnerSelector.for_chat delivers the bare runner_key ("opencode"),
        # never the "runner:<id>" routing key -- UserSetting validates
        # kb_chat_runner against bare APP_RUNNER_KEYS and
        # available_chat_runner_keys plucks bare runner_keys. Stubbing the
        # routing key here would exercise a shape the real selectors never
        # produce.
        allow(Knowledge::RunnerSelector).to receive(:for_chat)
          .with(user_setting: user_setting)
          .and_return([ "opencode", "openai" ])
      end

      it "retries the same bare-keyed runner after free-model rotation" do
        executor = described_class.new(user_setting: user_setting, operation: :chat)
        attempt = 0

        result = executor.execute do |runner|
          attempt += 1
          if runner == "opencode" && attempt == 1
            raise AgentHarness::RateLimitError, "rate limited"
          end

          "response from #{runner}"
        end

        expect(result).to eq("response from opencode")
        expect(attempt).to eq(2)
        expect(free_policy_runner.reload.tier_model_ids["high"]).to eq(free_model_high.model_id)
      end

      it "keys rotation RunnerState by the routing key, not the bare name" do
        executor = described_class.new(user_setting: user_setting, operation: :chat)

        executor.execute do |runner|
          raise AgentHarness::RateLimitError, "rate limited" if runner == "opencode"
          "ok"
        end

        routing_key_state = user.runner_states.find_by(runner_name: free_policy_runner.routing_key)
        expect(routing_key_state).to be_present
        expect(routing_key_state.rate_limited_model_ids).to include(free_model_high.model_id)
        expect(user.runner_states.where(runner_name: "opencode")).not_to exist
      end
    end
  end
end
