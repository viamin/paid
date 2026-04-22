# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CompleteReviewGoalActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  describe "#execute" do
    context "when a review was posted" do
      it "marks the agent run as completed" do
        agent_run = create(:agent_run, :running, :review_goal, project: project,
          review_posted_at: 1.minute.ago)

        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(agent_run.status).to eq("completed")
        expect(result[:success]).to be true
      end

      it "logs the completion" do
        agent_run = create(:agent_run, :running, :review_goal, project: project,
          review_posted_at: 1.minute.ago)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to change(AgentRunLog, :count).by(1)

        log = agent_run.agent_run_logs.last
        expect(log.content).to include("review goal finished")
      end

      it "enqueues ProcessRunQueueJob" do
        agent_run = create(:agent_run, :running, :review_goal, project: project,
          review_posted_at: 1.minute.ago)

        expect { activity.execute(agent_run_id: agent_run.id) }
          .to have_enqueued_job(ProcessRunQueueJob)
      end

      it "resets review_goal_retry_count on the issue" do
        issue = create(:issue, project: project, review_goal_retry_count: 2)
        agent_run = create(:agent_run, :running, :review_goal, project: project,
          issue: issue, review_posted_at: 1.minute.ago)

        activity.execute(agent_run_id: agent_run.id)

        expect(issue.reload.review_goal_retry_count).to eq(0)
      end

      it "does not overwrite cancelled runs" do
        issue = create(:issue, project: project, review_goal_retry_count: 2)
        agent_run = create(:agent_run, :cancelled, :review_goal, project: project,
          issue: issue, review_posted_at: 1.minute.ago)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be false
        expect(agent_run.reload.status).to eq("cancelled")
        expect(issue.reload.review_goal_retry_count).to eq(2)
      end
    end

    context "when no review was posted" do
      it "fails the agent run" do
        agent_run = create(:agent_run, :running, :review_goal, project: project)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /No review was posted/)

        agent_run.reload
        expect(agent_run.status).to eq("failed")
        expect(agent_run.error_message).to include("No review was posted")
      end
    end
  end
end
