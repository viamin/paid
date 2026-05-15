# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::FailureRecoveryService do
  describe ".call" do
    let(:project) { create(:project) }
    let(:anthropic_attempt) { { "provider" => "anthropic", "success" => false } }
    let(:openai_attempt) { { "provider" => "openai", "success" => false } }

    it "classifies common provider failures and selects the default recovery action" do
      agent_run = create(:agent_run, :failed, project: project,
        error_message: "AllProvidersExhausted: no available providers",
        providers_attempted: [ anthropic_attempt, openai_attempt ])

      result = described_class.call(agent_run: agent_run)

      expect(result.failure_category).to eq("provider_error")
      expect(result.chosen_action).to eq("retry_alternate_provider")
      expect(result.action_params).to include(
        "exclude_providers" => %w[anthropic openai],
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
        providers_attempted: [ anthropic_attempt ])

      result = described_class.call(
        agent_run: agent_run,
        policy_overrides: { "timeout" => "escalate_model" }
      )

      expect(result.failure_category).to eq("timeout")
      expect(result.chosen_action).to eq("escalate_model")
      expect(result.action_params).to include(
        "current_provider" => "anthropic",
        "policy_source" => "override"
      )
    end

    it "emits runner params for retry_same_provider actions" do
      agent_run = create(:agent_run, :timeout, project: project,
        error_message: "Agent execution timed out",
        providers_attempted: [ anthropic_attempt ])

      result = described_class.call(agent_run: agent_run)

      expect(result.chosen_action).to eq("retry_same_provider")
      expect(result.action_params).to include(
        "runner" => "anthropic",
        "policy_source" => "defaults"
      )
    end
  end
end
