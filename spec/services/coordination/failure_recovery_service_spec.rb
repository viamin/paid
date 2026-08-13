# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::FailureRecoveryService do
  describe ".call" do
    let(:project) { create(:project) }
    let(:anthropic_attempt) { { "runner" => "anthropic", "success" => false } }
    let(:openai_attempt) { { "runner" => "openai", "success" => false } }

    it "classifies common provider failures and selects the default recovery action" do
      agent_run = create(:agent_run, :failed, project: project,
        error_message: "AllProvidersExhausted: no available providers",
        runners_attempted: [ anthropic_attempt, openai_attempt ])

      result = described_class.call(agent_run: agent_run)

      expect(result.failure_category).to eq("runner_error")
      expect(result.chosen_action).to eq("retry_alternate_runner")
      expect(result.action_params).to include(
        "exclude_runners" => %w[anthropic openai],
        "policy_source" => "defaults"
      )
    end

    it "classifies common configuration failures and keeps the initial hook metadata" do
      agent_run = create(:agent_run, :failed, project: project,
        error_message: "McpProvisioningFailed: missing sidecar credentials")

      result = described_class.call(agent_run: agent_run)

      expect(result.failure_category).to eq("configuration_error")
      expect(result.chosen_action).to eq("reconfigure_and_retry")
      expect(result.failure_context).to include(
        "policy_source" => "defaults",
        "policy_key" => "failure_recovery"
      )
    end

    it "supports policy-driven action overrides without changing classification" do
      agent_run = create(:agent_run, :timeout, project: project,
        error_message: "Agent execution timed out",
        runners_attempted: [ anthropic_attempt ])

      result = described_class.call(
        agent_run: agent_run,
        policy_overrides: { "timeout" => "escalate_model" }
      )

      expect(result.failure_category).to eq("timeout")
      expect(result.chosen_action).to eq("escalate_model")
      expect(result.action_params).to include(
        "current_runner" => "anthropic",
        "policy_source" => "override"
      )
    end

    it "emits runner params for retry_same_provider actions" do
      agent_run = create(:agent_run, :timeout, project: project,
        error_message: "Agent execution timed out",
        runners_attempted: [ anthropic_attempt ])

      result = described_class.call(agent_run: agent_run)

      expect(result.chosen_action).to eq("retry_same_runner")
      expect(result.action_params).to include(
        "runner" => "anthropic",
        "policy_source" => "defaults"
      )
    end

    it "classifies token-budget terminations as a first-class failure category" do
      agent_run = create(:agent_run, :token_budget_exceeded, project: project,
        error_message: "guardrail: token_budget — Run consumed 250000 input tokens (budget: 100000)",
        runners_attempted: [ anthropic_attempt, openai_attempt ])

      result = described_class.call(agent_run: agent_run)

      expect(result.failure_category).to eq("token_budget")
      expect(result.chosen_action).to eq("retry_alternate_runner")
      expect(result.failure_subcategory).to eq("token_budget")
      expect(result.action_params).to include(
        "exclude_runners" => %w[anthropic openai],
        "policy_source" => "defaults"
      )
    end

    it "lets policy overrides route token-budget terminations without changing classification" do
      agent_run = create(:agent_run, :token_budget_exceeded, project: project,
        runners_attempted: [ anthropic_attempt ])

      result = described_class.call(
        agent_run: agent_run,
        policy_overrides: { "token_budget" => "pause_and_notify" }
      )

      expect(result.failure_category).to eq("token_budget")
      expect(result.chosen_action).to eq("pause_and_notify")
      expect(result.action_params).to include("policy_source" => "override")
    end
  end
end
