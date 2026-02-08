# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::Execute do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project, agent_type: "claude_code") }
  let(:prompt) { "Fix the authentication bug" }

  describe ".call" do
    context "when agent execution succeeds" do
      let(:response) do
        AgentHarness::Response.new(
          output: "Fixed the bug in auth.rb",
          exit_code: 0,
          duration: 45.2,
          provider: :claude,
          model: "claude-sonnet-4",
          tokens: { input: 1500, output: 800, total: 2300 }
        )
      end

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      it "returns a successful result" do
        result = described_class.call(agent_run: agent_run, prompt: prompt)

        expect(result).to be_success
        expect(result.response).to eq(response)
      end

      it "marks the agent run as completed" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        agent_run.reload
        expect(agent_run.status).to eq("completed")
        expect(agent_run.completed_at).to be_present
        expect(agent_run.duration_seconds).to eq(45)
      end

      it "tracks token usage on the agent run" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        agent_run.reload
        expect(agent_run.tokens_input).to eq(1500)
        expect(agent_run.tokens_output).to eq(800)
      end

      it "delegates token tracking to TokenUsageTracker" do
        expect(TokenUsageTracker).to receive(:track).with(
          agent_run: agent_run,
          tokens_input: 1500,
          tokens_output: 800
        )

        described_class.call(agent_run: agent_run, prompt: prompt)
      end

      it "logs agent output" do
        allow(TokenUsageTracker).to receive(:track)

        described_class.call(agent_run: agent_run, prompt: prompt)

        logs = agent_run.agent_run_logs
        system_logs = logs.where(log_type: "system")
        stdout_logs = logs.where(log_type: "stdout")

        expect(system_logs.pluck(:content)).to include(
          "Starting claude_code agent",
          match(/Prompt:/)
        )
        expect(stdout_logs.pluck(:content)).to include("Fixed the bug in auth.rb")
      end

      it "calls AgentHarness.send_message with correct parameters" do
        expect(AgentHarness).to receive(:send_message).with(
          prompt,
          provider: :claude,
          dangerous_mode: true
        ).and_return(response)

        described_class.call(agent_run: agent_run, prompt: prompt)
      end
    end

    context "when agent execution fails (non-zero exit)" do
      let(:response) do
        AgentHarness::Response.new(
          output: "Partial output",
          exit_code: 1,
          duration: 30.0,
          provider: :claude,
          error: "Compilation error in main.rb"
        )
      end

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      it "marks the agent run as failed" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        agent_run.reload
        expect(agent_run.status).to eq("failed")
        expect(agent_run.error_message).to eq("Compilation error in main.rb")
        expect(agent_run.completed_at).to be_present
      end

      it "returns a successful result (execution completed, agent failed)" do
        result = described_class.call(agent_run: agent_run, prompt: prompt)

        expect(result).to be_success
        expect(result.response).to eq(response)
      end

      it "logs the error output" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        stderr_logs = agent_run.agent_run_logs.where(log_type: "stderr")
        expect(stderr_logs.pluck(:content)).to include("Compilation error in main.rb")
      end
    end

    context "when agent times out" do
      before do
        allow(AgentHarness).to receive(:send_message)
          .and_raise(AgentHarness::TimeoutError.new("Timed out after 600s"))
      end

      it "marks the agent run as timeout" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.error_message).to include("timed out")
      end

      it "returns a failure result" do
        result = described_class.call(agent_run: agent_run, prompt: prompt)

        expect(result).to be_failure
        expect(result.error).to be_a(AgentHarness::TimeoutError)
      end

      it "logs the timeout" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        system_logs = agent_run.agent_run_logs.where(log_type: "system")
        expect(system_logs.pluck(:content)).to include("Execution timed out")
      end
    end

    context "when agent times out with nil timeout" do
      before do
        allow(AgentHarness).to receive(:send_message)
          .and_raise(AgentHarness::TimeoutError.new("Timed out"))
        allow(AgentHarness.configuration).to receive(:default_timeout).and_return(601)
      end

      it "uses the configured default timeout in the error message" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        agent_run.reload
        expect(agent_run.error_message).to eq("Agent execution timed out after 601 seconds")
      end
    end

    context "when agent times out with explicit timeout of 0" do
      before do
        allow(AgentHarness).to receive(:send_message)
          .and_raise(AgentHarness::TimeoutError.new("Timed out"))
      end

      # 0 is truthy in Ruby so `timeout || default` correctly preserves it
      it "uses 0 in the error message, not the default" do
        described_class.call(agent_run: agent_run, prompt: prompt, timeout: 0)

        agent_run.reload
        expect(agent_run.error_message).to eq("Agent execution timed out after 0 seconds")
      end
    end

    context "when agent-harness raises an error" do
      before do
        allow(AgentHarness).to receive(:send_message)
          .and_raise(AgentHarness::ProviderError.new("Provider unavailable"))
      end

      it "marks the agent run as failed" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        agent_run.reload
        expect(agent_run.status).to eq("failed")
        expect(agent_run.error_message).to eq("Provider unavailable")
      end

      it "returns a failure result" do
        result = described_class.call(agent_run: agent_run, prompt: prompt)

        expect(result).to be_failure
        expect(result.error).to be_a(AgentHarness::ProviderError)
      end

      it "logs the error" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        stderr_logs = agent_run.agent_run_logs.where(log_type: "stderr")
        system_logs = agent_run.agent_run_logs.where(log_type: "system")

        expect(stderr_logs.pluck(:content)).to include("Provider unavailable")
        expect(system_logs.pluck(:content)).to include("Execution failed: AgentHarness::ProviderError")
      end
    end

    context "with unsupported agent type" do
      let(:agent_run) { create(:agent_run, project: project, agent_type: "api") }

      it "raises ArgumentError" do
        expect {
          described_class.call(agent_run: agent_run, prompt: prompt)
        }.to raise_error(ArgumentError, /Unsupported agent type: api/)
      end
    end

    context "with custom timeout" do
      let(:response) do
        AgentHarness::Response.new(
          output: "Done",
          exit_code: 0,
          duration: 10.0,
          provider: :claude
        )
      end

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      it "passes custom timeout to agent-harness" do
        expect(AgentHarness).to receive(:send_message).with(
          prompt,
          provider: :claude,
          timeout: 1200,
          dangerous_mode: true
        ).and_return(response)

        described_class.call(agent_run: agent_run, prompt: prompt, timeout: 1200)
      end
    end

    context "when response has no tokens" do
      let(:response) do
        AgentHarness::Response.new(
          output: "Done",
          exit_code: 0,
          duration: 10.0,
          provider: :claude
        )
      end

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      it "skips token tracking" do
        expect(TokenUsageTracker).not_to receive(:track)

        described_class.call(agent_run: agent_run, prompt: prompt)
      end
    end
  end

  describe "provider mapping" do
    let(:response) do
      AgentHarness::Response.new(
        output: "Done",
        exit_code: 0,
        duration: 5.0,
        provider: :claude
      )
    end

    before do
      allow(AgentHarness).to receive(:send_message).and_return(response)
    end

    {
      "claude_code" => :claude,
      "cursor" => :cursor,
      "codex" => :codex,
      "copilot" => :github_copilot,
      "aider" => :aider,
      "gemini" => :gemini,
      "opencode" => :opencode,
      "kilocode" => :kilocode
    }.each do |agent_type, expected_provider|
      it "maps #{agent_type} to :#{expected_provider}" do
        run = create(:agent_run, project: project, agent_type: agent_type)

        expect(AgentHarness).to receive(:send_message).with(
          prompt,
          hash_including(provider: expected_provider)
        ).and_return(response)

        described_class.call(agent_run: run, prompt: prompt)
      end
    end
  end
end
