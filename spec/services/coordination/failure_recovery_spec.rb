# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::FailureRecovery do
  let(:project) { create(:project) }
  let(:workflow_id) { "recovery-workflow-#{SecureRandom.hex(4)}" }
  let(:anthropic_attempt) { { "provider" => "anthropic", "success" => false } }
  let(:openai_attempt) { { "provider" => "openai", "success" => false } }

  describe ".call" do
    context "with a rate-limited agent run" do
      let(:agent_run) do
        create(:agent_run, :rate_limited, project: project,
          parent_workflow_id: workflow_id,
          error_message: "RateLimit: exceeded quota")
      end

      it "classifies as rate_limit and selects retry_alternate_provider" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_success
        expect(result.failure_category).to eq("rate_limit")
        expect(result.chosen_action).to eq("retry_alternate_provider")
      end

      it "persists the classification" do
        result = described_class.call(agent_run: agent_run)

        classification = result.classification
        expect(classification).to be_persisted
        expect(classification.failure_category).to eq("rate_limit")
        expect(classification.chosen_action).to eq("retry_alternate_provider")
        expect(classification.action_status).to eq("pending")
        expect(classification.project).to eq(project)
        expect(classification.agent_run).to eq(agent_run)
      end
    end

    context "with an auth-expired agent run" do
      let(:agent_run) do
        create(:agent_run, :auth_expired, project: project,
          error_message: "AuthenticationError: token expired")
      end

      it "classifies as auth_failure and selects pause_and_notify" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_success
        expect(result.failure_category).to eq("auth_failure")
        expect(result.chosen_action).to eq("pause_and_notify")
      end
    end

    context "with a timed-out agent run" do
      let(:agent_run) do
        create(:agent_run, :timeout, project: project,
          error_message: "Agent execution timed out",
          providers_attempted: [ anthropic_attempt ])
      end

      it "classifies as timeout and selects retry_same_provider" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_success
        expect(result.failure_category).to eq("timeout")
        expect(result.chosen_action).to eq("retry_same_provider")
      end

      it "uses the last attempted provider when final_provider is unavailable" do
        result = described_class.call(agent_run: agent_run)

        expect(result.classification.action_params["provider"]).to eq("anthropic")
      end
    end

    context "with a provider exhaustion failure" do
      let(:agent_run) do
        create(:agent_run, :failed, project: project,
          parent_workflow_id: workflow_id,
          error_message: "AllProvidersExhausted: no available providers",
          providers_attempted: [ anthropic_attempt, openai_attempt ])
      end

      it "classifies as provider_error" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_success
        expect(result.failure_category).to eq("provider_error")
        expect(result.chosen_action).to eq("retry_alternate_provider")
      end

      it "includes providers_attempted in action_params" do
        result = described_class.call(agent_run: agent_run)

        expect(result.classification.action_params["exclude_providers"]).to eq(%w[anthropic openai])
      end
    end

    context "with a container provisioning failure" do
      let(:agent_run) do
        create(:agent_run, :failed, project: project,
          error_message: "ContainerNotProvisioned: pool exhausted")
      end

      it "classifies as container_error and selects reconfigure_and_retry" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_success
        expect(result.failure_category).to eq("container_error")
        expect(result.chosen_action).to eq("reconfigure_and_retry")
      end
    end

    context "with a dependency failure" do
      let(:agent_run) do
        create(:agent_run, :failed, project: project,
          parent_workflow_id: workflow_id,
          error_message: "dependency_failed: upstream task errored")
      end

      it "classifies as dependency_failure and selects cancel_workflow" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_success
        expect(result.failure_category).to eq("dependency_failure")
        expect(result.chosen_action).to eq("cancel_workflow")
      end
    end

    context "with an unknown failure" do
      let(:agent_run) do
        create(:agent_run, :failed, project: project,
          error_message: "Something completely unexpected happened")
      end

      it "classifies as unknown and selects pause_and_notify" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_success
        expect(result.failure_category).to eq("unknown")
        expect(result.chosen_action).to eq("pause_and_notify")
      end
    end

    context "with policy overrides" do
      let(:agent_run) do
        create(:agent_run, :timeout, project: project,
          error_message: "Agent timed out")
      end

      it "uses the override action instead of the default" do
        result = described_class.call(
          agent_run: agent_run,
          policy_overrides: { "timeout" => "escalate_model" }
        )

        expect(result).to be_success
        expect(result.failure_category).to eq("timeout")
        expect(result.chosen_action).to eq("escalate_model")
      end
    end

    context "with a guardrail violation" do
      let(:agent_run) do
        create(:agent_run, :failed, project: project,
          error_message: "Configuration error",
          guardrail_violation_type: "token_limit")
      end

      it "stores the guardrail violation as subcategory" do
        result = described_class.call(agent_run: agent_run)

        expect(result.classification.failure_subcategory).to eq("token_limit")
      end
    end

    context "with workflow context" do
      let(:agent_run) do
        create(:agent_run, :failed, project: project,
          parent_workflow_id: workflow_id,
          error_message: "timeout")
      end

      it "persists the parent_workflow_id" do
        result = described_class.call(agent_run: agent_run)

        expect(result.classification.parent_workflow_id).to eq(workflow_id)
      end
    end

    context "with failure context details" do
      let(:agent_run) do
        create(:agent_run, :failed, project: project,
          error_message: "AllProvidersExhausted",
          final_provider: "anthropic",
          providers_attempted: [ anthropic_attempt, openai_attempt ],
          provider_switches: 1)
      end

      it "captures structured failure context" do
        result = described_class.call(agent_run: agent_run)
        ctx = result.classification.failure_context

        expect(ctx["error_message"]).to eq("AllProvidersExhausted")
        expect(ctx["final_provider"]).to eq("anthropic")
        expect(ctx["providers_attempted"]).to eq([ anthropic_attempt, openai_attempt ])
        expect(ctx["provider_switches"]).to eq(1)
      end
    end
  end
end
