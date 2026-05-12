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
  end
end
