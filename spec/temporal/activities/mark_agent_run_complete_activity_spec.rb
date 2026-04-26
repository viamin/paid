# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkAgentRunCompleteActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  describe "#execute" do
    context "when goal is create_pr" do
      it "marks the agent run as no_output" do
        agent_run = create(:agent_run, :running, project: project)

        activity.execute(agent_run_id: agent_run.id)

        expect(agent_run.reload.status).to eq("no_output")
      end

      it "stores the reason in error_message" do
        agent_run = create(:agent_run, :running, project: project)

        activity.execute(agent_run_id: agent_run.id, reason: "no_changes")

        expect(agent_run.reload.error_message).to eq("no_changes")
      end
    end

    context "when goal is not create_pr" do
      it "marks the agent run as completed" do
        agent_run = create(:agent_run, :running, :create_issue_goal, project: project)

        activity.execute(agent_run_id: agent_run.id)

        expect(agent_run.reload.status).to eq("completed")
      end
    end

    it "logs the completion reason" do
      agent_run = create(:agent_run, :running, project: project)

      expect {
        activity.execute(agent_run_id: agent_run.id, reason: "no_changes")
      }.to change(AgentRunLog, :count).by(1)

      log = agent_run.agent_run_logs.last
      expect(log.content).to include("no_changes")
    end

    it "updates issue paid_state to completed for non-PR goals" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, :create_issue_goal, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.paid_state).to eq("completed")
    end

    it "updates issue paid_state to analyzed for analyze_issue goals" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, :analyze_issue_goal, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.paid_state).to eq("analyzed")
    end

    it "does not update issue paid_state for no_output create_pr runs" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "reports cancellation without completing issue state for cancelled runs" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :cancelled, :create_issue_goal, project: project, issue: issue)

      result = nil
      expect {
        result = activity.execute(agent_run_id: agent_run.id)
      }.not_to have_enqueued_job(ProcessRunQueueJob)

      expect(result).to include(skipped: true, cancelled: true)
      expect(agent_run.reload.status).to eq("cancelled")
      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "reports cancellation when completion loses a cancellation race" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, :create_issue_goal, project: project, issue: issue)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(agent_run).to receive(:complete!) do
        agent_run.cancel!
        false
      end

      result = nil
      expect {
        result = activity.execute(agent_run_id: agent_run.id)
      }.not_to have_enqueued_job(ProcessRunQueueJob)

      expect(result).to include(skipped: true, cancelled: true)
      expect(agent_run.reload.status).to eq("cancelled")
      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "reports active completion for completed runs" do
      agent_run = create(:agent_run, :running, :create_issue_goal, project: project)

      result = nil
      expect {
        result = activity.execute(agent_run_id: agent_run.id)
      }.to have_enqueued_job(ProcessRunQueueJob).once

      expect(result).to include(skipped: false, cancelled: false)
      expect(agent_run.reload.status).to eq("completed")
    end

    it "enqueues ProcessRunQueueJob" do
      agent_run = create(:agent_run, :running, project: project)

      expect { activity.execute(agent_run_id: agent_run.id) }
        .to have_enqueued_job(ProcessRunQueueJob)
    end

    it "increments draft_review_count for successful tracked no-change draft followups" do
      issue = create(:issue, :pull_request, project: project, pr_review_phase: "draft", draft_review_count: 1)
      agent_run = create(:agent_run, :running, project: project, issue: issue,
        count_toward_draft_review_round: true,
        expected_draft_review_count: 1)

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.draft_review_count).to eq(2)
    end

    it "records the draft round only after the run completes successfully" do
      issue = create(:issue, :pull_request, project: project, pr_review_phase: "draft", draft_review_count: 1)
      agent_run = create(:agent_run, :running, project: project, issue: issue,
        count_toward_draft_review_round: true,
        expected_draft_review_count: 1)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      # Default goal is create_pr, so the activity calls complete_no_output!
      expect(agent_run).to receive(:complete_no_output!).ordered.and_wrap_original do |method, **kwargs|
        # Draft round must NOT yet be recorded at this point
        expect(issue.reload.draft_review_count).to eq(1)
        method.call(**kwargs)
      end

      activity.execute(agent_run_id: agent_run.id)
      expect(issue.reload.draft_review_count).to eq(2)
    end

    it "does not increment draft_review_count for untracked runs" do
      issue = create(:issue, :pull_request, project: project, pr_review_phase: "draft", draft_review_count: 1)
      agent_run = create(:agent_run, :running, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.draft_review_count).to eq(1)
    end

    it "does not increment draft_review_count when completion fails" do
      issue = create(:issue, :pull_request, project: project, pr_review_phase: "draft", draft_review_count: 1)
      agent_run = create(:agent_run, :running, project: project, issue: issue,
        count_toward_draft_review_round: true,
        expected_draft_review_count: 1)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(agent_run).to receive(:complete_no_output!).and_raise(ActiveRecord::ConnectionTimeoutError)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(ActiveRecord::ConnectionTimeoutError)

      expect(issue.reload.draft_review_count).to eq(1)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
