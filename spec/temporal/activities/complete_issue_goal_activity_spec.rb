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
        expect(result[:issue_created]).to be true
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

      it "does not log or enqueue when the run is already cancelled" do
        agent_run = create(:agent_run, :cancelled, project: project,
          created_issue_url: "https://github.com/example/repo/issues/42",
          created_issue_number: 42)

        expect {
          expect {
            activity.execute(agent_run_id: agent_run.id)
          }.not_to change(AgentRunLog, :count)
        }.not_to have_enqueued_job(ProcessRunQueueJob)
      end

      it "reports finished runs as skipped" do
        agent_run = create(:agent_run, :cancelled, project: project,
          created_issue_url: "https://github.com/example/repo/issues/42",
          created_issue_number: 42)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result).to include(
          success: false,
          issue_created: true,
          skipped: true,
          finished: true,
          cancelled: true
        )
      end
    end

    context "when the agent did not create an issue" do
      it "returns issue_created: false without failing the run" do
        agent_run = create(:agent_run, :running, project: project)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:issue_created]).to be false
        expect(agent_run.reload.status).to eq("running")
      end

      it "logs the fallback message" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to change(AgentRunLog, :count).by(1)

        log = agent_run.agent_run_logs.last
        expect(log.content).to include("falling back to platform issue creation")
      end

      it "does not enqueue ProcessRunQueueJob" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.not_to have_enqueued_job(ProcessRunQueueJob)
      end

      it "reports cancelled runs as skipped instead of fallback candidates" do
        agent_run = create(:agent_run, :cancelled, project: project)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result).to include(
          success: false,
          issue_created: false,
          skipped: true,
          finished: true,
          cancelled: true
        )
      end
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
