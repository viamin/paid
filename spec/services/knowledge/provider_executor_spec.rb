# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ProviderExecutor do
  let(:user) { create(:user) }
  let(:user_setting) { user.settings }
  let(:project) { create(:project, account: user.account) }
  let(:knowledge_run) { create(:knowledge_run, project: project) }

  before do
    allow(Knowledge::ProviderSelector).to receive(:for_chat)
      .with(user_setting: user_setting)
      .and_return(%w[claude openai])
    allow(Knowledge::ProviderSelector).to receive(:for_embedding)
      .with(user_setting: user_setting)
      .and_return(%w[openai])
  end

  describe "#execute" do
    it "calls the block with the first available provider on success" do
      executor = described_class.new(user_setting: user_setting, operation: :chat)

      result = executor.execute { |provider| "response from #{provider}" }

      expect(result).to eq("response from claude")
    end

    it "falls back to next provider on RateLimitError" do
      executor = described_class.new(user_setting: user_setting, operation: :chat)
      call_count = 0

      result = executor.execute do |provider|
        call_count += 1
        raise AgentHarness::RateLimitError, "rate limited" if provider == "claude"
        "response from #{provider}"
      end

      expect(result).to eq("response from openai")
      expect(call_count).to eq(2)
    end

    it "falls back to next provider on generic AgentHarness::Error" do
      executor = described_class.new(user_setting: user_setting, operation: :chat)

      result = executor.execute do |provider|
        raise AgentHarness::Error, "provider error" if provider == "claude"
        "response from #{provider}"
      end

      expect(result).to eq("response from openai")
    end

    it "raises AllProvidersExhausted when all providers fail" do
      executor = described_class.new(user_setting: user_setting, operation: :chat)

      expect {
        executor.execute { |_provider| raise AgentHarness::Error, "failed" }
      }.to raise_error(
        Knowledge::ProviderExecutor::AllProvidersExhausted,
        /All providers exhausted for chat/
      )
    end

    it "raises AllProvidersExhausted when no providers available" do
      allow(Knowledge::ProviderSelector).to receive(:for_embedding).and_return([])

      executor = described_class.new(user_setting: user_setting, operation: :embedding)

      expect {
        executor.execute { |_provider| "result" }
      }.to raise_error(
        Knowledge::ProviderExecutor::AllProvidersExhausted,
        /No available providers/
      )
    end

    context "with knowledge_run tracking" do
      it "records provider attempts on the knowledge run" do
        executor = described_class.new(
          user_setting: user_setting,
          operation: :chat,
          knowledge_run: knowledge_run
        )

        executor.execute { |_provider| "ok" }

        knowledge_run.reload
        expect(knowledge_run.provider_attempts.size).to eq(1)
        expect(knowledge_run.provider_attempts.first["provider"]).to eq("claude")
      end

      it "records final_provider on success" do
        executor = described_class.new(
          user_setting: user_setting,
          operation: :chat,
          knowledge_run: knowledge_run
        )

        executor.execute { |_provider| "ok" }

        knowledge_run.reload
        expect(knowledge_run.final_provider).to eq("claude")
      end

      it "records multiple attempts on fallback" do
        executor = described_class.new(
          user_setting: user_setting,
          operation: :chat,
          knowledge_run: knowledge_run
        )

        executor.execute do |provider|
          raise AgentHarness::Error, "fail" if provider == "claude"
          "ok"
        end

        knowledge_run.reload
        expect(knowledge_run.provider_attempts.size).to eq(2)
        expect(knowledge_run.final_provider).to eq("openai")
      end
    end

    context "with ProviderState updates" do
      it "records success on ProviderState" do
        executor = described_class.new(user_setting: user_setting, operation: :chat)
        executor.execute { |_provider| "ok" }

        state = user.provider_states.find_by(provider_name: "claude")
        expect(state).to be_present
        expect(state.circuit_state).to eq("closed")
        expect(state.failure_count).to eq(0)
      end

      it "marks provider as rate limited on RateLimitError" do
        executor = described_class.new(user_setting: user_setting, operation: :chat)

        executor.execute do |provider|
          raise AgentHarness::RateLimitError, "rate limited" if provider == "claude"
          "ok"
        end

        state = user.provider_states.find_by(provider_name: "claude")
        expect(state).to be_present
        expect(state.rate_limited?).to be true
      end

      it "records failure on ProviderState for generic errors" do
        executor = described_class.new(user_setting: user_setting, operation: :chat)

        executor.execute do |provider|
          raise AgentHarness::Error, "error" if provider == "claude"
          "ok"
        end

        state = user.provider_states.find_by(provider_name: "claude")
        expect(state).to be_present
        expect(state.failure_count).to eq(1)
      end
    end
  end
end
