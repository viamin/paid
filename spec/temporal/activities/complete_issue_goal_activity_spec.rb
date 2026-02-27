# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CompleteIssueGoalActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  describe "#execute" do
    context "when the agent created an issue" do
      it "marks the agent run as completed with issue details" do
        agent_run = create(:agent_run, :running, project: project,
          created_issue_url: "https://github.com/example/repo/issues/42",
          created_issue_number: 42)

        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(agent_run.status).to eq("completed")
        expect(agent_run.created_issue_url).to eq("https://github.com/example/repo/issues/42")
        expect(agent_run.created_issue_number).to eq(42)
        expect(result[:success]).to be true
      end

      it "logs the completion" do
        agent_run = create(:agent_run, :running, project: project,
          created_issue_url: "https://github.com/example/repo/issues/42",
          created_issue_number: 42)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to change(AgentRunLog, :count).by(1)

        log = agent_run.agent_run_logs.last
        expect(log.content).to include("issue #42 created")
      end

      it "enqueues ProcessRunQueueJob" do
        agent_run = create(:agent_run, :running, project: project,
          created_issue_url: "https://github.com/example/repo/issues/42",
          created_issue_number: 42)

        expect { activity.execute(agent_run_id: agent_run.id) }
          .to have_enqueued_job(ProcessRunQueueJob)
      end
    end

    context "when the agent did not create an issue" do
      it "marks the agent run as failed" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, "Agent did not create an issue")

        expect(agent_run.reload.status).to eq("failed")
        expect(agent_run.error_message).to eq("Agent did not create an issue")
      end

      it "logs the failure" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError)

        log = agent_run.agent_run_logs.last
        expect(log.content).to include("no issue was created")
      end

      it "enqueues ProcessRunQueueJob" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          begin
            activity.execute(agent_run_id: agent_run.id)
          rescue Temporalio::Error::ApplicationError
            # expected
          end
        }.to have_enqueued_job(ProcessRunQueueJob)
      end
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
