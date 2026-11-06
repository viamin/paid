# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::AssessSourceClosureActivity do # @spec PARTIAL-CLOSEOUT-042
  let(:activity) { described_class.new }
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: owner, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }
  let(:agent_run) do
    create(:agent_run, :running, project: project, issue: issue, goal: "create_pr",
      branch_name: "agent/issue-7", result_commit_sha: "abc123def456")
  end
  let(:assessment) { { "gaps" => [], "criteria" => [ { "criterion" => "dispatch", "state" => "satisfied" } ] } }

  describe "#execute" do
    it "records the assessment and its source-closure disposition" do
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(assessment)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:disposition]).to eq("close")
      expect(agent_run.reload.reconciliation).to include("assessment", "source_closure")
    end

    it "reuses an assessment that is already recorded" do
      allow(Llm::AnalyzePartialCloseout).to receive(:call)
      agent_run.update!(reconciliation: { "assessment" => assessment })

      activity.execute(agent_run_id: agent_run.id)

      expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
    end

    # @spec PARTIAL-CLOSEOUT-042
    it "marks a transient transport failure as retryable" do
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(
        Llm::AnalyzePartialCloseout::AssessmentFailure.new("Partial closeout assessment timed out waiting for the runner.",
          category: "timeout")
      )

      expect { activity.execute(agent_run_id: agent_run.id) }
        .to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.type).to eq(described_class::FAILURE_TYPE)
          expect(error.non_retryable).to be false
        }
    end

    # @spec PARTIAL-CLOSEOUT-042
    it "marks an authentication failure as non-retryable" do
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(
        Llm::AnalyzePartialCloseout::AssessmentFailure.new("Reconnect its credential and retry.",
          category: "authentication_unavailable")
      )

      expect { activity.execute(agent_run_id: agent_run.id) }
        .to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.non_retryable).to be true
        }
    end

    # @spec PARTIAL-CLOSEOUT-043
    it "records the failed step, the pushed revision, and the attempt before failing" do
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(
        Llm::AnalyzePartialCloseout::AssessmentFailure.new("Partial closeout assessment timed out waiting for the runner.",
          category: "timeout")
      )

      expect { activity.execute(agent_run_id: agent_run.id) }.to raise_error(Temporalio::Error::ApplicationError)

      state = PartialCloseouts::SourceClosureRecoveryState.state(agent_run.reload)
      expect(state).to include(
        "status" => "retrying",
        "step" => "assess_source_closure",
        "branch" => "agent/issue-7",
        "commit_sha" => "abc123def456",
        "attempts" => 1,
        "failure_category" => "timeout"
      )
    end
  end
end
