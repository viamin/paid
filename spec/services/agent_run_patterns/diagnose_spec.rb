# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatterns::Diagnose, :no_db do
  describe ".call" do
    let(:pattern) do
      AgentRunPatterns::Detect::Pattern.new(
        type: :failure_streak,
        goal: "enhance_issue",
        severity: :error,
        details: { error_messages: error_messages, streak_length: 3, total_runs: 3, failure_rate: 1.0 }
      )
    end

    context "with LLM provider errors" do
      let(:error_messages) do
        [
          "No LLM provider produced an issue enhancement",
          "No LLM provider produced an issue enhancement",
          "No LLM provider produced an issue enhancement"
        ]
      end

      it "diagnoses LLM provider error" do
        result = described_class.call(pattern)

        expect(result.root_cause).to eq("LLM Provider Error")
        expect(result.category).to eq("llm_provider")
        expect(result.confidence).to be > 0.5
        expect(result.remediation).to include("provider")
      end
    end

    context "with GitHub API errors" do
      let(:error_messages) do
        [
          "GitHub API error: 403 Forbidden",
          "GitHub API error: 403 Forbidden"
        ]
      end

      it "diagnoses GitHub API error" do
        result = described_class.call(pattern)

        expect(result.root_cause).to eq("GitHub API Error")
        expect(result.category).to eq("github_api")
      end
    end

    context "with timeout errors" do
      let(:error_messages) do
        [
          "Execution timed out after 3600s",
          "Timeout waiting for container response"
        ]
      end

      it "diagnoses timeout" do
        result = described_class.call(pattern)

        expect(result.root_cause).to eq("Timeout")
        expect(result.category).to eq("timeout")
      end
    end

    context "with container errors" do
      let(:error_messages) do
        [
          "Container error: OCI runtime exec format error",
          "Docker error: cannot allocate memory"
        ]
      end

      it "diagnoses container error" do
        result = described_class.call(pattern)

        expect(result.root_cause).to eq("Container Error")
        expect(result.category).to eq("container")
      end
    end

    context "with unknown errors" do
      let(:error_messages) do
        [ "Something completely unexpected happened" ]
      end

      it "returns unknown diagnosis" do
        result = described_class.call(pattern)

        expect(result.root_cause).to eq("Unknown")
        expect(result.category).to eq("unknown")
        expect(result.confidence).to eq(0.0)
      end
    end

    context "with empty error messages" do
      let(:error_messages) { [] }

      it "returns unknown diagnosis" do
        result = described_class.call(pattern)

        expect(result.root_cause).to eq("Unknown")
        expect(result.category).to eq("unknown")
      end
    end

    context "with error cluster pattern" do
      let(:pattern) do
        AgentRunPatterns::Detect::Pattern.new(
          type: :error_cluster,
          goal: "enhance_issue",
          severity: :error,
          details: {
            sample_messages: [
              "No LLM provider produced an issue enhancement",
              "No LLM provider produced an issue enhancement"
            ],
            error_pattern: "No LLM provider..."
          }
        )
      end

      let(:error_messages) { [] }

      it "uses sample_messages from error cluster details" do
        result = described_class.call(pattern)

        expect(result.root_cause).to eq("LLM Provider Error")
      end
    end

    context "with evidence bundle sourced from per-attempt failures" do
      let(:pattern) do
        AgentRunPatterns::Detect::Pattern.new(
          type: :error_cluster,
          goal: "enhance_issue",
          severity: :error,
          details: {
            error_pattern: "All runners exhausted: Codex, Claude",
            evidence_bundle: AgentRunPatterns::EvidenceBundle.new(
              outer_errors: [ "All runners exhausted: Codex, Claude" ],
              runner_attempts: [
                {
                  runner: "runner:42",
                  error_type: "provider_error",
                  error_message: "Model metadata for `gpt-4o` not found",
                  diagnostics: { details: [ "Model metadata for `gpt-4o` not found" ] }
                }
              ],
              log_tails: [],
              runner_configs: [
                {
                  runner_key: "cursor",
                  auth_type: "api_key",
                  tier_model_ids: { low: "gpt-4o" },
                  provider_api_key_configured: true
                }
              ],
              aggregate_stats: { run_count: 3 }
            ).to_payload
          }
        )
      end

      let(:error_messages) { [] }

      it "classifies from per-attempt evidence instead of the outer wrapper alone" do
        result = described_class.call(pattern)

        expect(result.root_cause).to eq("LLM Provider Error")
        expect(result.category).to eq("llm_provider")
        expect(result.confidence).to eq(0.5)
      end
    end

    context "when one document matches multiple patterns in the same category" do
      let(:pattern) do
        AgentRunPatterns::Detect::Pattern.new(
          type: :error_cluster,
          goal: "enhance_issue",
          severity: :error,
          details: {
            evidence_bundle: AgentRunPatterns::EvidenceBundle.new(
              outer_errors: [
                "Provider error: model not found and api key invalid",
                "Something completely unrelated happened"
              ],
              runner_attempts: [],
              log_tails: [],
              runner_configs: [],
              aggregate_stats: { run_count: 2 }
            ).to_payload
          }
        )
      end

      let(:error_messages) { [] }

      it "counts the document once when computing confidence" do
        result = described_class.call(pattern)

        expect(result.root_cause).to eq("LLM Provider Error")
        expect(result.category).to eq("llm_provider")
        expect(result.confidence).to eq(0.5)
      end
    end
  end
end
