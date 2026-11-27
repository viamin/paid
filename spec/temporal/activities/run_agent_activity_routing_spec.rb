# frozen_string_literal: true

require "rails_helper"

# @spec TEST-SUITE-031
RSpec.describe Activities::RunAgentActivity, :no_db do
  describe ".container_executable?" do
    it "recognizes codex as container executable" do
      expect(described_class.container_executable?("codex")).to be true
    end

    it "recognizes gemini as container executable" do
      expect(described_class.container_executable?("gemini")).to be true
    end

    it "recognizes kilocode as container executable" do
      expect(described_class.container_executable?("kilocode")).to be true
    end

    it "recognizes opencode as container executable" do
      expect(described_class.container_executable?("opencode")).to be true
    end

    it "treats copilot as container executable via autopilot mode" do
      expect(described_class.container_executable?("copilot")).to be true
    end

    it "recognizes claude_code via agent type mapping" do
      expect(described_class.container_executable?("claude_code")).to be true
    end

    it "rejects unknown runners" do
      expect(described_class.container_executable?("unknown")).to be false
    end
  end

  describe "harness-generated commands" do
    it "generates codex command with sandbox bypass through agent-harness" do
      plan = Runners::HarnessExecutionPlan.for_runner_key(
        runner_key: "codex", prompt: "test", options: { dangerous_mode: true }
      )
      expect(plan.command).to include("codex", "exec")
      expect(plan.command).to include("--dangerously-bypass-approvals-and-sandbox")
    end

    it "generates claude command with dangerous-mode flags through agent-harness" do
      plan = Runners::HarnessExecutionPlan.for_runner_key(
        runner_key: "claude", prompt: "test", options: { dangerous_mode: true }
      )
      expect(plan.command).to include("claude", "--print", "--dangerously-skip-permissions")
    end

    it "generates copilot env that bypasses approval prompts in dangerous mode" do
      plan = Runners::HarnessExecutionPlan.for_runner_key(
        runner_key: "copilot", prompt: "test", options: { dangerous_mode: true }
      )
      expect(plan.command).to include("copilot", "--autopilot")
      expect(plan.env).to include("COPILOT_ALLOW_ALL" => "true")
    end
  end

  describe ".runner_order" do
    it "returns only the primary runner when fallback is disabled" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: false,
        fallback_runners: %w[cursor gemini]
      )

      expect(result).to eq([ "claude_code" ])
    end

    it "deduplicates canonical runners in fallback order" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[claude cursor gemini]
      )

      expect(result).to eq(%w[claude_code cursor gemini])
    end

    it "includes codex in fallback order when listed" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[codex cursor]
      )

      expect(result).to eq(%w[claude_code codex cursor])
    end

    it "includes gemini in fallback order when listed" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[gemini codex]
      )

      expect(result).to eq(%w[claude_code gemini codex])
    end

    it "includes kilocode in fallback order when listed" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[kilocode codex]
      )

      expect(result).to eq(%w[claude_code kilocode codex])
    end

    it "includes opencode in fallback order when listed" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[opencode codex]
      )

      expect(result).to eq(%w[claude_code opencode codex])
    end

    it "includes copilot in fallback order as a container-executable runner" do
      result = described_class.runner_order(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[copilot codex]
      )

      expect(result).to eq(%w[claude_code copilot codex])
    end
  end

  describe ".runner_attempt_count" do
    it "matches provider_order size for deduplicated fallback runners" do
      count = described_class.runner_attempt_count(
        agent_type: "claude_code",
        fallback_enabled: true,
        fallback_runners: %w[claude cursor gemini]
      )

      expect(count).to eq(3)
    end
  end
end
