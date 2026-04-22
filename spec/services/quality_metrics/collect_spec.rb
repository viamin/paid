# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::Collect do
  describe ".call" do
    let(:agent_run) { create(:agent_run, :completed, iterations: 3) }

    it "creates a quality metric for the agent run" do
      expect { described_class.call(agent_run: agent_run) }.to change(QualityMetric, :count).by(1)
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

    context "with excluded status (timeout, auth_expired, rate_limited)" do
      AgentRun::QUALITY_EXCLUDED_STATUSES.each do |excluded_status|
        it "records nil composite_score for #{excluded_status} runs" do
          run = create(:agent_run, status: excluded_status)

          metric = described_class.call(agent_run: run)

          expect(metric.composite_score).to be_nil
          expect(metric.scores).to eq({ "excluded_status" => excluded_status })
          expect(metric.metadata["exclusion_reason"]).to eq("non_quality_failure")
        end
      end

      it "still records a composite_score for failed (non-excluded) runs" do
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
