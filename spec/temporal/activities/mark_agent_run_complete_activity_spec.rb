# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::MarkAgentRunCompleteActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  describe "#execute" do
    it "marks the agent run as completed" do
      agent_run = create(:agent_run, :running, project: project)

      activity.execute(agent_run_id: agent_run.id)

      expect(agent_run.reload.status).to eq("completed")
    end

    it "logs the completion reason" do
      agent_run = create(:agent_run, :running, project: project)

      expect {
        activity.execute(agent_run_id: agent_run.id, reason: "no_changes")
      }.to change(AgentRunLog, :count).by(1)

      log = agent_run.agent_run_logs.last
      expect(log.content).to include("no_changes")
    end

    it "updates issue paid_state to completed when issue exists" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.paid_state).to eq("completed")
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

    it "records the draft round before completing the run" do
      issue = create(:issue, :pull_request, project: project, pr_review_phase: "draft", draft_review_count: 1)
      agent_run = create(:agent_run, :running, project: project, issue: issue,
        count_toward_draft_review_round: true,
        expected_draft_review_count: 1)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      expect(agent_run).to receive(:complete!).ordered.and_wrap_original do |method, *args|
        expect(issue.reload.draft_review_count).to eq(2)
        method.call(*args)
      end

      activity.execute(agent_run_id: agent_run.id)
    end

    it "does not increment draft_review_count for untracked runs" do
      issue = create(:issue, :pull_request, project: project, pr_review_phase: "draft", draft_review_count: 1)
      agent_run = create(:agent_run, :running, project: project, issue: issue)

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.draft_review_count).to eq(1)
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
