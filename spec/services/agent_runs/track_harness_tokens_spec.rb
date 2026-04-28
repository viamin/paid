# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::TrackHarnessTokens do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project, agent_type: "claude_code") }

  def build_response(model:, provider: :claude, input: 1000, output: 200)
    AgentHarness::Response.new(
      output: "ok",
      exit_code: 0,
      duration: 1.0,
      provider: provider,
      model: model,
      tokens: { input: input, output: output, total: input + output }
    )
  end

  describe "#call" do
    context "when response has a model" do
      it "stores the response model on the run_summary record" do
        described_class.call(agent_run: agent_run, response: build_response(model: "claude-sonnet-4"))

        expect(agent_run.token_usages.find_by!(request_type: "run_summary").llm_model).to eq("claude-sonnet-4")
      end
    end

    context "when response.model is nil" do
      it "falls back to the provider name" do
        described_class.call(agent_run: agent_run, response: build_response(model: nil, provider: :anthropic))

        expect(agent_run.token_usages.find_by!(request_type: "run_summary").llm_model).to eq("anthropic")
        expect(agent_run.token_usages.find_by!(request_type: "run_delta").llm_model).to eq("anthropic")
      end
    end

    context "when response.model is blank" do
      it "still falls back to the provider name" do
        described_class.call(agent_run: agent_run, response: build_response(model: "", provider: :claude))

        expect(agent_run.token_usages.find_by!(request_type: "run_summary").llm_model).to eq("claude")
      end
    end
  end
end
