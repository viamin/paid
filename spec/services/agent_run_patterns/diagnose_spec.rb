# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatterns::Diagnose, :no_db do
  let(:account) { Struct.new(:id).new(42) }
  let(:pattern) do
    AgentRunPatterns::Detect::Pattern.new(
      type: :error_cluster,
      goal: "enhance_issue",
      severity: :error,
      details: {
        fingerprint: "fp-123",
        error_pattern: "All runners exhausted: Codex, Claude",
        evidence_bundle: evidence_bundle.to_payload
      }
    )
  end
  let(:evidence_bundle) do
    AgentRunPatterns::EvidenceBundle.new(
      outer_errors: [ "All runners exhausted after retries" ],
      runner_attempts: [
        {
          runner: "runner:42",
          error_type: "provider_error",
          error_message: "GitHub API error: 403 Forbidden",
          diagnostics: { details: [ "rate limit remaining: 0" ] }
        }
      ],
      log_tails: [],
      runner_configs: [],
      aggregate_stats: {
        distinct_project_ids: [ 7 ],
        distinct_runner_ids: [ 42 ]
      }
    )
  end
  let(:llm_response) do
    {
      root_cause: "GitHub API quota exhausted on runner fallback",
      confidence: 0.92,
      proposed_action: "mark_runner_unavailable",
      action_target: { type: "runner", id: "42" },
      evidence_pointers: [ "runner_attempts[0].error_message" ]
    }
  end

  before do
    allow(Llm::TextMode).to receive(:options).and_return({})
  end

  describe ".call" do
    it "returns a validated LLM diagnosis when the output matches the enum" do
      allow(AgentHarness).to receive(:send_message).and_return(
        AgentHarness::Response.new(
          output: llm_response.to_json,
          exit_code: 0,
          duration: 2.0,
          provider: :claude,
          model: "claude-sonnet-4-6",
          tokens: { input: 100, output: 40, total: 140 }
        )
      )

      result = described_class.call(pattern, account: account)

      expect(result.root_cause).to eq("GitHub API quota exhausted on runner fallback")
      expect(result.confidence).to eq(0.92)
      expect(result.proposed_action).to eq("mark_runner_unavailable")
      expect(result.action_target).to eq({ "type" => "runner", "id" => "42" })
      expect(result.evidence_pointers).to eq([ "runner_attempts[0].error_message" ])
    end

    context "when the LLM proposes an out-of-enum action" do
      before do
        allow(AgentHarness).to receive(:send_message).and_return(
          AgentHarness::Response.new(
            output: llm_response.merge(
              root_cause: "GitHub rate limit issue",
              confidence: 0.95,
              proposed_action: "restart_everything"
            ).to_json,
            exit_code: 0,
            duration: 2.0,
            provider: :claude,
            model: "claude-sonnet-4-6",
            tokens: { input: 100, output: 40, total: 140 }
          )
        )
        allow(Rails.logger).to receive(:warn)
      end

      it "falls back to regex classification" do
        result = described_class.call(pattern, account: account)

        expect(result.root_cause).to eq("LLM Provider Error")
        expect(result.proposed_action).to eq("notify")
        expect(result.action_target).to eq({ "type" => "account", "id" => "42" })
        expect(result.evidence_pointers).to include("runner_attempts[0].error_message")
        expect(Rails.logger).to have_received(:warn).with(
          hash_including(
            message: "agent_run_patterns.diagnose_fell_back",
            reason: "invalid_proposed_action",
            fingerprint: "fp-123"
          )
        )
      end
    end

    it "falls back to regex classification when LLM usage is disabled" do
      result = described_class.call(pattern, account: account, allow_llm: false)

      expect(result.root_cause).to eq("LLM Provider Error")
      expect(result.proposed_action).to eq("notify")
      expect(result.action_target).to eq({ "type" => "account", "id" => "42" })
    end

    it "returns unknown when there is no usable evidence" do
      empty_pattern = AgentRunPatterns::Detect::Pattern.new(
        type: :failure_streak,
        goal: "enhance_issue",
        severity: :error,
        details: { fingerprint: "fp-empty", error_messages: [] }
      )

      result = described_class.call(empty_pattern, account: account, allow_llm: false)

      expect(result.root_cause).to eq("Unknown")
      expect(result.confidence).to eq(0.0)
      expect(result.proposed_action).to eq("notify")
    end
  end
end
