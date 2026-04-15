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

      it "records run_summary without aggregates, then persists delta as run_delta when no proxy records exist" do
        expect(TokenUsageTracker).to receive(:track).with(
          agent_run: agent_run,
          usage: {
            tokens_input: 1500,
            tokens_output: 800,
            llm_model: "claude-sonnet-4",
            request_type: "run_summary"
          },
          update_aggregates: false
        )
        expect(TokenUsageTracker).to receive(:track).with(
          agent_run: agent_run,
          usage: {
            tokens_input: 1500,
            tokens_output: 800,
            llm_model: "claude-sonnet-4",
            request_type: "run_delta"
          }
        )

        described_class.call(agent_run: agent_run, prompt: prompt)
      end

      it "skips delta record when proxy records fully cover tracking" do
        create(:token_usage, agent_run: agent_run, request_type: "agent",
               input_tokens: 1500, output_tokens: 800)

        expect(TokenUsageTracker).to receive(:track).with(
          agent_run: agent_run,
          usage: hash_including(request_type: "run_summary"),
          update_aggregates: false
        )
        # No run_delta expected when proxy fully covers.
        # Use keyword arg matching (not positional hash) since track uses kwargs.
        expect(TokenUsageTracker).not_to receive(:track).with(
          agent_run: anything,
          usage: hash_including(request_type: "run_delta")
        )

        described_class.call(agent_run: agent_run, prompt: prompt)
      end

      it "persists only the delta as run_delta when proxy records partially cover tracking" do
        create(:token_usage, agent_run: agent_run, request_type: "agent",
               input_tokens: 1000, output_tokens: 500)

        expect(TokenUsageTracker).to receive(:track).with(
          agent_run: agent_run,
          usage: hash_including(request_type: "run_summary"),
          update_aggregates: false
        )
        expect(TokenUsageTracker).to receive(:track).with(
          agent_run: agent_run,
          usage: {
            tokens_input: 500,
            tokens_output: 300,
            llm_model: "claude-sonnet-4",
            request_type: "run_delta"
          }
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

    context "when aider returns normalized token usage" do
      let(:agent_run) { create(:agent_run, :aider, project: project) }

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      %w[gpt-4o claude-3-5-sonnet-20241022 gemini-2.5-pro].each do |backend_model|
        context "with backend model #{backend_model}" do
          let(:response) do
            AgentHarness::Response.new(
              output: "Updated the implementation",
              exit_code: 0,
              duration: 12.4,
              provider: :aider,
              model: backend_model,
              tokens: { input: 1_000_000, output: 500_000, total: 1_500_000 }
            )
          end

          it "persists billable token usage with the backend model name" do
            described_class.call(agent_run: agent_run, prompt: prompt)

            usages = agent_run.token_usages.order(:request_type)

            expect(usages.pluck(:request_type, :input_tokens, :output_tokens, :llm_model)).to eq([
              [ "run_delta", 1_000_000, 500_000, backend_model ],
              [ "run_summary", 1_000_000, 500_000, backend_model ]
            ])

            aggregate = TokenUsages::Aggregate.new(scope: agent_run.token_usages.billable).call

            expect(aggregate[:total_input_tokens]).to eq(1_000_000)
            expect(aggregate[:total_output_tokens]).to eq(500_000)
            expect(aggregate[:cost_by_model].keys).to contain_exactly(backend_model)
            expect(aggregate[:cost_by_request_type]).to eq("run_delta" => usages.billable.sum(:cost_cents))
          end
        end
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

    context "when agent-harness raises an authentication error" do
      before do
        allow(AgentHarness).to receive(:send_message)
          .and_raise(AgentHarness::AuthenticationError.new("OAuth session expired"))
      end

      it "marks the agent run as auth_expired" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        agent_run.reload
        expect(agent_run.status).to eq("auth_expired")
        expect(agent_run.error_message).to eq("OAuth session expired")
        expect(agent_run.auth_provider).to eq("claude")
      end

      it "returns a failure result" do
        result = described_class.call(agent_run: agent_run, prompt: prompt)

        expect(result).to be_failure
        expect(result.error).to be_a(AgentHarness::AuthenticationError)
      end

      it "logs the authentication expiry" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        system_logs = agent_run.agent_run_logs.where(log_type: "system")
        expect(system_logs.pluck(:content)).to include("Authentication expired for claude")
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

    context "when kilocode returns token totals" do
      let(:agent_run) { create(:agent_run, :kilocode, project: project) }
      let(:kilocode_model) { "anthropic/claude-sonnet-4.5" }
      let(:delta) { agent_run.token_usages.find_by!(request_type: "run_delta") }
      let(:aggregate) { TokenUsages::Aggregate.call }
      let(:response) do
        AgentHarness::Response.new(
          output: "Applied the requested change",
          exit_code: 0,
          duration: 12.5,
          provider: :kilocode,
          model: kilocode_model,
          tokens: { input: 3200, output: 1200, total: 4400 }
        )
      end

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      it "depends on agent-harness versions that parse kilocode token totals" do
        # Kilocode runtime token extraction lives upstream in agent-harness.
        # This ingestion spec guards Paid's contract against regressing to a
        # gem version older than the 0.7.0 release that added that support.
        expect(Gem.loaded_specs.fetch("agent-harness").version).to be >= Gem::Version.new("0.7.0")
      end

      it "persists run_summary and run_delta records for the kilocode model" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        summary = agent_run.token_usages.find_by!(request_type: "run_summary")
        delta = agent_run.token_usages.find_by!(request_type: "run_delta")

        aggregate_failures do
          expect(summary.input_tokens).to eq(3200)
          expect(summary.output_tokens).to eq(1200)
          expect(summary.llm_model).to eq(kilocode_model)
          expect(delta.input_tokens).to eq(3200)
          expect(delta.output_tokens).to eq(1200)
          expect(delta.llm_model).to eq(kilocode_model)
        end
      end

      it "tracks only the missing billable delta when proxy coverage is partial" do
        TokenUsageTracker.track(
          agent_run: agent_run,
          usage: {
            tokens_input: 1000,
            tokens_output: 200,
            llm_model: kilocode_model,
            request_type: "agent"
          }
        )
        described_class.call(agent_run: agent_run, prompt: prompt)

        aggregate_failures do
          expect(delta.input_tokens).to eq(2200)
          expect(delta.output_tokens).to eq(1000)
          expect(agent_run.reload.tokens_input).to eq(3200)
          expect(agent_run.tokens_output).to eq(1200)
          expect(aggregate[:total_input_tokens]).to eq(3200)
          expect(aggregate[:total_output_tokens]).to eq(1200)
          expect(aggregate[:cost_by_request_type]).to include("agent", "run_delta")
          expect(aggregate[:cost_by_request_type]).not_to include("run_summary")
        end
      end
    end

    context "when a copilot run returns token usage" do
      let(:agent_run) { create(:agent_run, :copilot, project: project) }
      let(:response) do
        AgentHarness::Response.new(
          output: "Done",
          exit_code: 0,
          duration: 12.0,
          provider: :github_copilot,
          model: "claude-sonnet-4.5",
          tokens: { input: 2100, output: 900, total: 3000 }
        )
      end

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      it "tracks run summary and delta using the reported model" do
        described_class.call(agent_run: agent_run, prompt: prompt)

        expect(agent_run.token_usages.pluck(:request_type, :llm_model, :input_tokens, :output_tokens)).to contain_exactly(
          [ "run_summary", "claude-sonnet-4.5", 2100, 900 ],
          [ "run_delta", "claude-sonnet-4.5", 2100, 900 ]
        )

        agent_run.reload
        expect(agent_run.tokens_input).to eq(2100)
        expect(agent_run.tokens_output).to eq(900)
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
