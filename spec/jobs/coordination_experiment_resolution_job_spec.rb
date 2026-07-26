# frozen_string_literal: true

require "rails_helper"

RSpec.describe CoordinationExperimentResolutionJob do
  let(:job) { described_class.new }
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project) }

  let(:experiment) do
    create(:coordination_experiment, account: account, min_samples_per_variant: 2)
  end
  let!(:control) do
    create(:coordination_experiment_variant,
      coordination_experiment: experiment,
      policy_config: experiment.control_policy,
      is_control: true,
      sample_count: 2,
      avg_coordination_score: 0.6,
      total_coordination_score: 1.2)
  end
  let!(:variant) do
    create(:coordination_experiment_variant,
      coordination_experiment: experiment,
      policy_config: { "parallel_execution" => { "max_batch_size" => 1 } },
      sample_count: 2,
      avg_coordination_score: 0.8,
      total_coordination_score: 1.6)
  end

  def build_assignment(variant, workflow_suffix:, score: 0.8)
    create(:coordination_experiment_assignment,
      coordination_experiment: experiment,
      coordination_experiment_variant: variant,
      project: project,
      issue: issue,
      workflow_id: "#{variant.id}-#{workflow_suffix}",
      outcome_status: "recorded",
      coordination_score: score,
      outcome_metrics: {
        "success" => true,
        "task_count" => 2,
        "completed_tasks" => 2,
        "failed_tasks" => 0,
        "dependency_failed_tasks" => 0,
        "conflict_detected" => false,
        "manual_review_required" => false,
        "total_cost_cents" => 100,
        "total_duration_seconds" => 120,
        "aggregated_pr_created" => false
      })
  end

  before do
    build_assignment(control, workflow_suffix: "0", score: 0.6)
    build_assignment(control, workflow_suffix: "1", score: 0.6)
    build_assignment(variant, workflow_suffix: "0")
    build_assignment(variant, workflow_suffix: "1")
  end

  describe "#perform" do
    context "when experiment is ready for promotion" do
      it "completes the experiment and sets the winner" do
        job.perform

        experiment.reload
        expect(experiment.status).to eq("completed")
        expect(experiment.winner_variant).to eq(variant)
        expect(experiment.completed_at).to be_present
      end

      it "logs the completion" do
        expect(Rails.logger).to receive(:info).with(
          hash_including(
            message: "coordination_experiment_resolution.completed",
            experiment_id: experiment.id,
            winner_variant_id: variant.id
          )
        )

        job.perform
      end
    end

    context "when experiment needs more data" do
      before do
        experiment.update!(min_samples_per_variant: 100)
      end

      it "does not complete the experiment" do
        job.perform

        expect(experiment.reload.status).to eq("running")
        expect(experiment.reload.winner_variant).to be_nil
      end

      it "logs that more data is needed" do
        expect(Rails.logger).to receive(:info).with(
          hash_including(
            message: "coordination_experiment_resolution.more_data_needed",
            experiment_id: experiment.id
          )
        )

        job.perform
      end
    end

    context "when experiment has no non-control variants" do
      before do
        variant.destroy
      end

      it "does not complete the experiment" do
        job.perform

        expect(experiment.reload.status).to eq("running")
      end

      it "logs that there is no candidate" do
        expect(Rails.logger).to receive(:info).with(
          hash_including(
            message: "coordination_experiment_resolution.no_candidate",
            experiment_id: experiment.id
          )
        )

        job.perform
      end
    end

    context "when guardrails fail" do
      before do
        # Make the variant worse than the control on coordination score
        variant.update!(avg_coordination_score: 0.4, total_coordination_score: 0.8)
        variant.coordination_experiment_assignments.update_all(coordination_score: 0.4)
      end

      it "completes the experiment with the control variant as winner" do
        job.perform

        experiment.reload
        expect(experiment.status).to eq("completed")
        expect(experiment.winner_variant).to eq(control)
        expect(experiment.completed_at).to be_present
      end

      it "logs the guardrail failures" do
        expect(Rails.logger).to receive(:info).with(
          hash_including(
            message: "coordination_experiment_resolution.guardrail_failed",
            experiment_id: experiment.id,
            winner_variant_id: control.id
          )
        )

        job.perform
      end
    end

    context "when the experiment is already completed" do
      before { experiment.update!(status: "completed") }

      it "does not attempt to resolve the experiment again" do
        expect(CoordinationExperiments::PromotionReadiness).not_to receive(:call)

        job.perform
      end
    end

    context "when multiple experiments are running" do
      def build_second_experiment
        account_b = create(:account)
        project_b = create(:project, account: account_b)
        issue_b = create(:issue, project: project_b)
        exp = create(:coordination_experiment, account: account_b, min_samples_per_variant: 2)
        ctrl = create(:coordination_experiment_variant,
          coordination_experiment: exp, policy_config: exp.control_policy,
          is_control: true, sample_count: 2, avg_coordination_score: 0.5,
          total_coordination_score: 1.0)
        var = create(:coordination_experiment_variant,
          coordination_experiment: exp,
          policy_config: { "parallel_execution" => { "max_batch_size" => 1 } },
          sample_count: 2, avg_coordination_score: 0.9, total_coordination_score: 1.8)
        metrics = {
          "success" => true, "task_count" => 1, "completed_tasks" => 1,
          "failed_tasks" => 0, "dependency_failed_tasks" => 0,
          "conflict_detected" => false, "manual_review_required" => false,
          "total_cost_cents" => 50, "total_duration_seconds" => 60,
          "aggregated_pr_created" => false
        }
        2.times do |i|
          create(:coordination_experiment_assignment,
            coordination_experiment: exp, coordination_experiment_variant: ctrl,
            project: project_b, issue: issue_b, workflow_id: "b-ctrl-#{i}",
            outcome_status: "recorded", coordination_score: 0.5, outcome_metrics: metrics)
          create(:coordination_experiment_assignment,
            coordination_experiment: exp, coordination_experiment_variant: var,
            project: project_b, issue: issue_b, workflow_id: "b-var-#{i}",
            outcome_status: "recorded", coordination_score: 0.9, outcome_metrics: metrics)
        end
        exp
      end

      it "resolves all running experiments" do
        experiment_b = build_second_experiment

        job.perform

        expect(experiment.reload.status).to eq("completed")
        expect(experiment_b.reload.status).to eq("completed")
      end
    end

    context "when an individual experiment raises an error" do
      before do
        allow(CoordinationExperiments::PromotionReadiness).to receive(:call)
          .and_raise(StandardError, "unexpected failure")
      end

      it "logs a warning and continues without raising" do
        expect(Rails.logger).to receive(:warn).with(
          hash_including(
            message: "coordination_experiment_resolution.failed_for_experiment",
            experiment_id: experiment.id
          )
        )

        expect { job.perform }.not_to raise_error
      end
    end
  end

  describe "GoodJob concurrency" do
    it "limits the job to one concurrent execution" do
      expect(described_class.good_job_concurrency_config[:total_limit]).to eq(1)
    end
  end
end
