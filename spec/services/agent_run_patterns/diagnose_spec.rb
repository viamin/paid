# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunPatterns::Diagnose do
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
  end
end
