# frozen_string_literal: true

require "rails_helper"
require "temporalio/client"

RSpec.describe CoordinationPolicyEvolutionJob do
  let(:job) { described_class.new }
  let(:temporal_client) { instance_double(Temporalio::Client) }

  before do
    allow(Paid).to receive(:temporal_client).and_return(temporal_client)
    allow(temporal_client).to receive(:start_workflow)
    allow(ProjectWorkflowManager).to receive(:start_polling)
  end

  describe "#perform" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    def create_decomposition_decisions(project, count:, created_at: 1.day.ago)
      issue = create(:issue, project: project)
      count.times do
        create(:decomposition_decision, project: project, issue: issue, created_at: created_at)
      end
    end

    def create_orchestration_decisions(project, actor:, count:, created_at: 1.day.ago)
      count.times do
        create(:orchestration_decision, :without_agent_run, project: project, actor: actor,
          created_at: created_at)
      end
    end

    context "with an account that has sufficient decomposition decisions" do
      before { create_decomposition_decisions(project, count: described_class::MIN_DECISIONS) }

      it "starts a workflow for decomposition policy type" do
        job.perform(policy_type: "decomposition")

        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::CoordinationPolicyEvolutionWorkflow,
          hash_including(account_id: account.id, policy_type: "decomposition"),
          hash_including(
            id: "coordination-policy-evolution-#{account.id}-decomposition-#{Date.current}",
            task_queue: Paid.agent_task_queue
          )
        )
      end
    end

    context "with an account that has sufficient recovery decisions" do
      before do
        create_orchestration_decisions(project,
          actor: "coordination_failure_recovery",
          count: described_class::MIN_DECISIONS)
      end

      it "starts a workflow for recovery policy type" do
        job.perform(policy_type: "recovery")

        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::CoordinationPolicyEvolutionWorkflow,
          hash_including(account_id: account.id, policy_type: "recovery"),
          hash_including(task_queue: Paid.agent_task_queue)
        )
      end
    end

    context "with an account that has sufficient escalation decisions" do
      before do
        create_orchestration_decisions(project,
          actor: "coordination_escalation_service",
          count: described_class::MIN_DECISIONS)
      end

      it "starts a workflow for escalation policy type" do
        job.perform(policy_type: "escalation")

        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::CoordinationPolicyEvolutionWorkflow,
          hash_including(account_id: account.id, policy_type: "escalation"),
          hash_including(task_queue: Paid.agent_task_queue)
        )
      end
    end

    context "with an account that has insufficient decisions" do
      before { create_decomposition_decisions(project, count: described_class::MIN_DECISIONS - 1) }

      it "does not start any workflows" do
        job.perform(account_id: account.id, policy_type: "decomposition")

        expect(temporal_client).not_to have_received(:start_workflow)
      end
    end

    context "with decisions older than the lookback window" do
      before do
        create_decomposition_decisions(project, count: described_class::MIN_DECISIONS,
          created_at: (described_class::LOOKBACK_DAYS + 1).days.ago)
      end

      it "does not start any workflows" do
        job.perform(account_id: account.id, policy_type: "decomposition")

        expect(temporal_client).not_to have_received(:start_workflow)
      end
    end

    context "when the account has a running coordination experiment" do
      before do
        create_decomposition_decisions(project, count: described_class::MIN_DECISIONS)
        create(:coordination_experiment, account: account, status: "running")
      end

      it "skips accounts with running experiments" do
        job.perform(account_id: account.id, policy_type: "decomposition")

        expect(temporal_client).not_to have_received(:start_workflow)
      end
    end

    context "when the account has a completed coordination experiment (not running)" do
      before do
        create_decomposition_decisions(project, count: described_class::MIN_DECISIONS)
        create(:coordination_experiment, account: account, status: "completed")
      end

      it "starts the evolution workflow" do
        job.perform(account_id: account.id, policy_type: "decomposition")

        expect(temporal_client).to have_received(:start_workflow).once
      end
    end

    context "when scoped to a specific account" do
      let(:account_b) { create(:account) }
      let(:project_b) { create(:project, account: account_b) }

      before do
        create_decomposition_decisions(project, count: described_class::MIN_DECISIONS)
        create_decomposition_decisions(project_b, count: described_class::MIN_DECISIONS)
      end

      it "only starts a workflow for the specified account" do
        job.perform(account_id: account.id, policy_type: "decomposition")

        expect(temporal_client).to have_received(:start_workflow).once
        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::CoordinationPolicyEvolutionWorkflow,
          hash_including(account_id: account.id),
          anything
        )
      end
    end

    context "when no policy_type is specified" do
      let(:recovery_project) { create(:project, account: account) }

      before do
        create_decomposition_decisions(project, count: described_class::MIN_DECISIONS)
        create_orchestration_decisions(recovery_project,
          actor: "coordination_failure_recovery",
          count: described_class::MIN_DECISIONS)
      end

      it "starts workflows for all eligible policy types for the account" do
        job.perform(account_id: account.id)

        # One call per eligible policy type (decomposition + recovery; escalation has no data)
        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::CoordinationPolicyEvolutionWorkflow,
          hash_including(policy_type: "decomposition", account_id: account.id),
          anything
        )
        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::CoordinationPolicyEvolutionWorkflow,
          hash_including(policy_type: "recovery", account_id: account.id),
          anything
        )
      end
    end

    context "when workflow start raises an error" do
      before do
        create_decomposition_decisions(project, count: described_class::MIN_DECISIONS)
        allow(temporal_client).to receive(:start_workflow).and_raise(StandardError, "connection lost")
      end

      it "logs a warning and does not raise" do
        expect(Rails.logger).to receive(:warn).with(
          hash_including(
            message: "coordination_policy_evolution.job_failed_for_account",
            account_id: account.id
          )
        )

        expect { job.perform(policy_type: "decomposition") }.not_to raise_error
      end
    end

    context "when using idempotent workflow IDs" do
      before { create_decomposition_decisions(project, count: described_class::MIN_DECISIONS) }

      it "uses a date-scoped workflow ID to prevent duplicate runs on the same day" do
        job.perform(account_id: account.id, policy_type: "decomposition")

        expected_id = "coordination-policy-evolution-#{account.id}-decomposition-#{Date.current}"
        expect(temporal_client).to have_received(:start_workflow).with(
          anything,
          anything,
          hash_including(id: expected_id)
        )
      end
    end
  end
end
