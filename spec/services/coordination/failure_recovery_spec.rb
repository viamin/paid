# frozen_string_literal: true

require "rails_helper"

RSpec.describe Coordination::FailureRecovery do
  let(:project) { create(:project) }
  let(:workflow_id) { "recovery-workflow-#{SecureRandom.hex(4)}" }
  let(:anthropic_attempt) { { "runner" => "anthropic", "success" => false } }
  let(:openai_attempt) { { "runner" => "openai", "success" => false } }

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

      it "logs a retry orchestration decision" do
        expect {
          described_class.call(agent_run: agent_run)
        }.to change(OrchestrationDecision, :count).by(1)

        decision = OrchestrationDecision.last
        expect(decision.decision_type).to eq("retry")
        expect(decision.actor).to eq("coordination_failure_recovery")
        expect(decision.context["decision_status"]).to eq("applied")
        expect(decision.inputs).to include(
          "failure_category" => "rate_limit",
          "chosen_action" => "retry_alternate_provider",
          "policy_source" => "defaults",
          "policy_key" => "failure_recovery"
        )
        expect(decision.outputs).to include(
          "chosen_action" => "retry_alternate_provider",
          "action_status" => "pending",
          "policy_source" => "defaults"
        )
      end

      it "returns a failed result when applied decision persistence fails" do
        service = described_class.new(agent_run: agent_run)
        allow(service).to receive(:build_decision_result).and_return([])

        expect {
          result = service.call

          expect(result).not_to be_success
          expect(result.error).to include("must be an object")
        }.to change(OrchestrationDecision, :count).by(1)

        decision = OrchestrationDecision.last
        expect(decision.decision_type).to eq("retry")
        expect(decision.context["decision_status"]).to eq("failed")
        expect(decision.inputs).to include(
          "failure_category" => "rate_limit",
          "chosen_action" => "retry_alternate_provider",
          "policy_source" => "defaults"
        )
        expect(decision.outputs).to include(
          "chosen_action" => "retry_alternate_provider",
          "error_class" => "ActiveRecord::RecordInvalid"
        )
      end
    end

    context "with a non-failure agent run" do
      let(:agent_run) { create(:agent_run, :completed, project: project) }

      it "rejects the run before persisting a classification" do
        expect {
          result = described_class.call(agent_run: agent_run)

          expect(result).not_to be_success
          expect(result.error).to eq("agent run status must be a failure status")
        }.not_to change(FailureClassification, :count)
      end

      it "logs a noop orchestration decision" do
        expect {
          described_class.call(agent_run: agent_run)
        }.to change(OrchestrationDecision, :count).by(1)

        decision = OrchestrationDecision.last
        expect(decision.decision_type).to eq("noop")
        expect(decision.context["decision_status"]).to eq("noop")
        expect(decision.outputs).to include("reason" => "non_failure_status")
      end

      it "returns a failed result when noop decision persistence fails" do
        allow(OrchestrationDecision).to receive(:record!).and_raise(
          ActiveRecord::RecordInvalid.new(OrchestrationDecision.new)
        )

        result = described_class.call(agent_run: agent_run)

        expect(result).not_to be_success
        expect(result.error).to include("Validation failed")
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

      it "logs the mapped action when failed decision persistence falls back" do
        service = described_class.new(agent_run: agent_run)
        allow(service).to receive(:build_decision_result).and_return([])

        expect {
          result = service.call

          expect(result).not_to be_success
          expect(result.error).to include("must be an object")
        }.to change(OrchestrationDecision, :count).by(1)

        decision = OrchestrationDecision.last
        expect(decision.decision_type).to eq("pause")
        expect(decision.context["decision_status"]).to eq("failed")
        expect(decision.inputs).to include(
          "failure_category" => "auth_failure",
          "chosen_action" => "pause_and_notify"
        )
        expect(decision.outputs).to include(
          "chosen_action" => "pause_and_notify",
          "error_class" => "ActiveRecord::RecordInvalid"
        )
      end
    end

    context "with a timed-out agent run" do
      let(:agent_run) do
        create(:agent_run, :timeout, project: project,
          error_message: "Agent execution timed out",
          runners_attempted: [ anthropic_attempt ])
      end

      it "classifies as timeout and selects retry_same_provider" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_success
        expect(result.failure_category).to eq("timeout")
        expect(result.chosen_action).to eq("retry_same_provider")
      end

      it "uses the last attempted provider when final_runner is unavailable" do
        result = described_class.call(agent_run: agent_run)

        expect(result.classification.action_params["runner"]).to eq("anthropic")
      end

      it "falls back to the effective provider when no provider metadata was recorded" do
        agent_run.update!(runners_attempted: [], final_runner: nil, agent_type: "codex")

        result = described_class.call(agent_run: agent_run)

        expect(result.classification.action_params["runner"]).to eq("codex")
      end

      it "classifies from the enqueued snapshot even if the row was later retried" do
        agent_run.update!(status: "retried")

        result = described_class.call(
          agent_run: agent_run,
          run_snapshot: {
            status: "timeout",
            error_message: "Agent execution timed out",
            providers_attempted: [ anthropic_attempt ]
          }
        )

        expect(result).to be_success
        expect(result.failure_category).to eq("timeout")
        expect(result.chosen_action).to eq("retry_same_provider")

        decision = OrchestrationDecision.last
        expect(decision.decision_type).to eq("retry")
        expect(decision.context["decision_status"]).to eq("applied")
        expect(decision.inputs).to include(
          "failure_category" => "timeout",
          "agent_run_status" => "timeout"
        )
      end
    end

    context "with a provider exhaustion failure" do
      let(:agent_run) do
        create(:agent_run, :failed, project: project,
          parent_workflow_id: workflow_id,
          error_message: "AllProvidersExhausted: no available providers",
          runners_attempted: [ anthropic_attempt, openai_attempt ])
      end

      it "classifies as provider_error" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_success
        expect(result.failure_category).to eq("provider_error")
        expect(result.chosen_action).to eq("retry_alternate_provider")
      end

      it "includes runners_attempted in action_params" do
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

      it "logs escalation decisions when the override escalates the model" do
        described_class.call(
          agent_run: agent_run,
          policy_overrides: { "timeout" => "escalate_model" }
        )

        decision = OrchestrationDecision.last
        expect(decision.decision_type).to eq("escalate")
        expect(decision.context["decision_status"]).to eq("applied")
        expect(decision.inputs).to include(
          "failure_category" => "timeout",
          "chosen_action" => "escalate_model",
          "policy_source" => "override"
        )
      end

      it "preserves the selected action when decision persistence fails" do
        invalid_record = FailureClassification.new
        allow(FailureClassification).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid_record))

        result = described_class.call(
          agent_run: agent_run,
          policy_overrides: { "timeout" => "escalate_model" }
        )

        expect(result).not_to be_success

        decision = OrchestrationDecision.last
        expect(decision.decision_type).to eq("escalate")
        expect(decision.context["decision_status"]).to eq("failed")
        expect(decision.inputs).to include(
          "failure_category" => "timeout",
          "chosen_action" => "escalate_model",
          "policy_source" => "override"
        )
        expect(decision.outputs["chosen_action"]).to eq("escalate_model")
        expect(decision.outputs["error_class"]).to eq("ActiveRecord::RecordInvalid")
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
          final_runner: "anthropic",
          runners_attempted: [ anthropic_attempt, openai_attempt ],
          runner_switches: 1)
      end

      it "captures structured failure context" do
        result = described_class.call(agent_run: agent_run)
        ctx = result.classification.failure_context

        expect(ctx["error_message"]).to eq("AllProvidersExhausted")
        expect(ctx["final_runner"]).to eq("anthropic")
        expect(ctx["runners_attempted"]).to eq([ anthropic_attempt, openai_attempt ])
        expect(ctx["runner_switches"]).to eq(1)
        expect(ctx["policy_source"]).to eq("defaults")
      end
    end
  end
end
