# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::Collect do
  describe ".call" do
    let(:agent_run) { create(:agent_run, :completed, iterations: 3) }

    before do
      allow(QualityPause::Check).to receive(:call)
    end

    def create_linked_scaling_assignments!(parent_workflow_id:)
      agent_run.update!(parent_workflow_id: parent_workflow_id)
      observation = create(:scaling_observation, project: agent_run.project, issue: agent_run.issue, workflow_id: parent_workflow_id)
      experiment = create(:scaling_experiment, project: agent_run.project)
      assignment = create(:scaling_experiment_assignment,
        scaling_experiment: experiment,
        project: agent_run.project,
        issue: agent_run.issue,
        scaling_observation: observation)
      iteration_experiment = create(:scaling_experiment,
        project: agent_run.project,
        dimension: "iteration_count",
        values_tested: [ 1, 3 ],
        control_value: 1)
      iteration_assignment = create(:scaling_experiment_assignment,
        scaling_experiment: iteration_experiment,
        project: agent_run.project,
        issue: agent_run.issue,
        scaling_observation: observation,
        execution_plan: {
          "dimension" => "iteration_count",
          "requested_iteration_count" => 3
        })

      [ observation, assignment, iteration_assignment ]
    end

    def expect_scaling_result_refresh_for(*assignments, observation:)
      assignments.each do |assignment|
        expect(ScalingExperiments::RecordResult).to have_received(:call).with(
          assignment: assignment,
          scaling_observation: observation
        )
      end
    end

    it "creates a quality metric for the agent run" do
      expect { described_class.call(agent_run: agent_run) }.to change(QualityMetric, :count).by(1)
    end

    it "checks for quality pauses after recording an eligible metric" do
      described_class.call(agent_run: agent_run)

      expect(QualityPause::Check).to have_received(:call).with(agent_run: agent_run)
    end

    it "sets iteration score in scores hash" do
      metric = described_class.call(agent_run: agent_run)

      expect(metric.scores["iterations"]).to be_present
    end

    it "calculates a composite score" do
      metric = described_class.call(agent_run: agent_run)

      expect(metric.composite_score).to be_present
    end

    it "does not create duplicate metrics" do
      described_class.call(agent_run: agent_run)

      expect { described_class.call(agent_run: agent_run) }.not_to change(QualityMetric, :count)
    end

    it "refreshes linked scaling experiment results for orchestration child runs" do
      observation, assignment, iteration_assignment = create_linked_scaling_assignments!(
        parent_workflow_id: "feature-wf-123"
      )

      allow(ScalingExperiments::RecordResult).to receive(:call)

      described_class.call(agent_run: agent_run)

      expect_scaling_result_refresh_for(assignment, iteration_assignment, observation:)
    end

    context "with create_pr goal" do
      it "includes agent_rerun_count but omits review_comment_count until collected" do
        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores).to include("agent_rerun_count")
        expect(metric.scores).not_to include("review_comment_count")
      end

      it "omits merge status until finalized human feedback is collected" do
        agent_run.issue.update!(pr_review_phase: "ready")

        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores).not_to include("pr_merged")
      end

      it "includes review_comment_count when metadata is populated" do
        # First create metric, then populate metadata as HumanFeedbackCollectionJob would
        metric = described_class.call(agent_run: agent_run)
        metric.update!(metadata: { "review_comment_count" => 2 })

        # Re-collect to pick up the metadata
        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores["review_comment_count"]).to eq(0.8)
      end

      it "sets agent_rerun_count to 1.0 for first run" do
        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores["agent_rerun_count"]).to eq(1.0)
      end

      it "omits review_comment_count and agent_rerun_count when no PR exists" do
        failed_run = create(:agent_run, :completed, pull_request_number: nil)

        metric = described_class.call(agent_run: failed_run)

        expect(metric.scores).not_to include("review_comment_count", "agent_rerun_count")
      end

      it "degrades agent_rerun_count for multiple runs on same issue" do
        issue = agent_run.issue
        create(:agent_run, :completed, issue: issue, project: agent_run.project)

        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores["agent_rerun_count"]).to eq(0.85)
      end

      it "records quality scores for linked strategy experiment assignments" do
        experiment = create(:strategy_experiment,
          account: agent_run.project.account,
          strategy_name: "review_settings",
          status: "running",
          started_at: Time.current)
        variant = create(:strategy_experiment_variant, strategy_experiment: experiment)
        assignment = create(:strategy_experiment_assignment,
          strategy_experiment: experiment,
          strategy_experiment_variant: variant,
          agent_run: agent_run)

        metric = described_class.call(agent_run: agent_run)

        expect(assignment.reload.quality_score.to_f).to eq(metric.composite_score.to_f)
        expect(variant.reload.sample_count).to eq(1)
      end
    end

    context "with focused create_pr goal" do
      let(:agent_run) { create(:agent_run, :completed, focus: "ci_fix", iterations: 3) }

      it "uses focus-specific weights for the composite score" do
        metric = described_class.call(agent_run: agent_run)

        expect(metric.composite_score).to eq(0.9333)
      end

      it "skips irrelevant general PR metrics" do
        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores).to include("iterations", "lint_clean")
        expect(metric.scores).not_to include(
          "pr_created",
          "pr_merged",
          "review_comment_count",
          "agent_rerun_count"
        )
      end
    end

    context "with issue_implementation focus" do
      let(:agent_run) { create(:agent_run, :completed, focus: "issue_implementation", iterations: 3) }

      it "falls back to general create_pr scoring until focus attribution exists" do
        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores).to include("pr_created", "iterations", "lint_clean", "agent_rerun_count")
        expect(metric.scores).not_to include("focus_resolved")
      end
    end

    context "with create_issue goal" do
      let(:agent_run) do
        create(:agent_run, :with_created_issue, status: "completed",
          started_at: 10.minutes.ago, completed_at: Time.current, duration_seconds: 600)
      end

      it "includes issue_created score" do
        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores["issue_created"]).to eq(1.0)
      end

      it "does not include PR-specific scores" do
        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores).not_to include("pr_created", "pr_merged", "iterations")
      end
    end

    context "with review goal" do
      let(:agent_run) { create(:agent_run, :with_review) }

      it "includes review_posted score" do
        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores["review_posted"]).to eq(1.0)
      end

      it "does not include PR-specific scores" do
        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores).not_to include("pr_created", "pr_merged", "iterations")
      end
    end

    context "with enhance_issue goal" do
      let(:agent_run) { create(:agent_run, :enhance_issue_goal, :completed, pull_request_number: nil) }

      it "includes comment and question scores from the enhancement comment log" do
        agent_run.agent_run_logs.create!(
          log_type: "stdout",
          content: "#{Activities::EnhanceIssueActivity::COMMENT_MARKER}\n## Clarifying questions\n1. What should happen?\n2. Who owns rollout?"
        )

        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores).to include(
          "comment_posted" => 1.0,
          "question_count" => 0.6667
        )
        expect(metric.metadata).to include(
          "comment_length" => be_positive,
          "question_count" => 2
        )
      end

      it "does not include PR-specific scores" do
        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores).not_to include("pr_created", "pr_merged", "iterations")
      end

      it "scores an already-recorded enhancement comment without question data" do
        agent_run.agent_run_logs.create!(
          log_type: "system",
          content: "Enhancement comment already exists: https://github.com/example/repo/issues/1#issuecomment-123"
        )

        metric = described_class.call(agent_run: agent_run)

        expect(metric.scores).to eq("comment_posted" => 1.0)
        expect(metric.metadata).to eq({})
      end
    end

    context "with operational failure" do
      AgentRun::QUALITY_EXCLUDED_STATUSES.each do |excluded_status|
        it "records nil composite_score for #{excluded_status} runs" do
          run = create(:agent_run, status: excluded_status)

          metric = described_class.call(agent_run: run)

          expect(metric.composite_score).to be_nil
          expect(metric.scores).to eq({ "excluded_status" => excluded_status })
          expect(metric.metadata["exclusion_reason"]).to eq("operational_failure")
          expect(QualityPause::Check).not_to have_received(:call).with(agent_run: run)
        end
      end

      it "records nil composite_score for failed runs with provider exhaustion" do
        run = create(:agent_run, status: "failed", error_message: "All providers exhausted: claude_code")

        metric = described_class.call(agent_run: run)

        expect(metric.composite_score).to be_nil
        expect(metric.metadata["exclusion_reason"]).to eq("operational_failure")
      end

      it "records nil composite_score for failed runs with Docker exec errors" do
        run = create(:agent_run, status: "failed", error_message: "Docker exec error: container crashed")

        metric = described_class.call(agent_run: run)

        expect(metric.composite_score).to be_nil
      end

      it "records nil composite_score for failed runs with worktree conflicts" do
        run = create(:agent_run, status: "failed", error_message: "Branch foo has an active worktree from agent run 42")

        metric = described_class.call(agent_run: run)

        expect(metric.composite_score).to be_nil
      end

      it "records a composite_score for failed runs with nil error_message" do
        run = create(:agent_run, status: "failed", error_message: nil)

        metric = described_class.call(agent_run: run)

        expect(metric.composite_score).not_to be_nil
        expect(metric.scores).not_to include("excluded_status")
      end

      it "records a composite_score for failed runs with agent-level errors" do
        run = create(:agent_run, status: "failed", error_message: "Agent exited with code 1")

        metric = described_class.call(agent_run: run)

        expect(metric.composite_score).not_to be_nil
        expect(metric.scores).not_to include("excluded_status")
      end

      it "still records a composite_score for completed runs" do
        run = create(:agent_run, :completed)

        metric = described_class.call(agent_run: run)

        expect(metric.composite_score).not_to be_nil
        expect(metric.scores).not_to include("excluded_status")
      end
    end

    context "with A/B test assignment" do
      let(:prompt) { create(:prompt, :with_version) }
      let(:ab_test) { create(:ab_test, prompt: prompt, status: "running", started_at: Time.current) }
      let!(:variant) { create(:ab_test_variant, ab_test: ab_test, is_control: true) }
      let!(:assignment) { create(:ab_test_assignment, ab_test: ab_test, ab_test_variant: variant, agent_run: agent_run) }

      it "sets quality_score on the assignment" do
        described_class.call(agent_run: agent_run)

        expect(assignment.reload.quality_score).to be_present
      end

      it "updates variant aggregate stats" do
        expect { described_class.call(agent_run: agent_run) }
          .to change { variant.reload.sample_count }.by(1)
      end

      it "adjusts variant aggregates on re-collection without changing sample_count" do
        described_class.call(agent_run: agent_run)

        expect { described_class.call(agent_run: agent_run) }
          .not_to change { variant.reload.sample_count }
      end
    end

    context "with configuration experiment assignment" do
      let(:configuration_experiment) { create(:configuration_experiment, status: "running", started_at: Time.current) }
      let!(:variant) { create(:configuration_experiment_variant, configuration_experiment: configuration_experiment, is_control: true) }
      let!(:assignment) do
        create(:configuration_experiment_assignment,
          configuration_experiment: configuration_experiment,
          configuration_experiment_variant: variant,
          agent_run: agent_run)
      end

      it "sets quality_score on the assignment" do
        described_class.call(agent_run: agent_run)

        expect(assignment.reload.quality_score).to be_present
      end

      it "records a bundle outcome for optimization" do
        agent_run.update!(configuration_bundle: create(:configuration_bundle, account: agent_run.project.account))

        described_class.call(agent_run: agent_run)

        expect(agent_run.reload.bundle_outcomes.sole).to have_attributes(
          success: true,
          cost_cents: agent_run.cost_cents
        )
        expect(agent_run.bundle_outcomes.sole.quality_score).to be_present
      end

      it "updates variant aggregate stats" do
        expect { described_class.call(agent_run: agent_run) }
          .to change { variant.reload.sample_count }.by(1)
      end

      it "adjusts variant aggregates on re-collection without changing sample_count" do
        described_class.call(agent_run: agent_run)

        expect { described_class.call(agent_run: agent_run) }
          .not_to change { variant.reload.sample_count }
      end

      it "auto-completes the experiment when collection reaches the minimum sample count" do
        configuration_experiment.update!(min_samples_per_variant: 2)
        test_variant = create(:configuration_experiment_variant, configuration_experiment: configuration_experiment)
        result = ConfigurationExperiments::Analyze::Result.new(status: :control_wins)

        create(:configuration_experiment_assignment,
          configuration_experiment: configuration_experiment,
          configuration_experiment_variant: variant,
          agent_run: create(:agent_run),
          quality_score: 0.9)
        variant.update!(sample_count: 1, total_quality_score: 0.9, avg_quality_score: 0.9)

        create_list(:configuration_experiment_assignment, 2,
          configuration_experiment: configuration_experiment,
          configuration_experiment_variant: test_variant,
          quality_score: 0.3)
        test_variant.update!(sample_count: 2, total_quality_score: 0.6, avg_quality_score: 0.3)

        allow(ConfigurationExperiments::Analyze).to receive(:call).and_return(result)

        described_class.call(agent_run: agent_run)

        expect(configuration_experiment.reload.status).to eq("completed")
      end
    end

    context "with prompt_version" do
      let(:prompt) { create(:prompt, :with_version) }
      let(:agent_run) { create(:agent_run, :completed, iterations: 3, prompt_version: prompt.current_version) }

      it "updates prompt version usage stats" do
        described_class.call(agent_run: agent_run)

        pv = prompt.current_version.reload
        expect(pv.usage_count).to eq(1)
        expect(pv.avg_quality_score).to be_present
      end
    end
  end
end
