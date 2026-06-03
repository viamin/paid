# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RequeueInfraFailureActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  describe "#execute" do
    it "converts a failed run to rate_limited with a reset delay" do
      agent_run = create(:agent_run, :failed, project: project,
        error_message: "Failed to pull image postgres:16")

      result = activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(result[:requeued]).to be true
      expect(agent_run.status).to eq("rate_limited")
      expect(agent_run.error_message).to include("Pre-runner infra failure")
      expect(agent_run.error_message).to include("Failed to pull image")
      expect(agent_run.rate_limited_until).to be_within(10.seconds).of(2.minutes.from_now)
      expect(agent_run.stale_requeue_count).to eq(1)
    end

    it "restores issue paid_state to in_progress" do
      issue = create(:issue, project: project, paid_state: "failed")
      agent_run = create(:agent_run, :failed, project: project, issue: issue,
        error_message: "Failed to pull image postgres:16")

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "does not requeue when stale_requeue_count is at the limit" do
      agent_run = create(:agent_run, :failed, project: project,
        error_message: "Failed to pull image postgres:16",
        stale_requeue_count: 3)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:requeued]).to be false
      expect(result[:reason]).to eq("limit_reached")
      expect(agent_run.reload.status).to eq("failed")
    end

    it "does not requeue when status is not failed" do
      agent_run = create(:agent_run, :completed, project: project)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:requeued]).to be false
      expect(result[:reason]).to eq("not_failed")
    end

    it "increments stale_requeue_count on each requeue" do
      agent_run = create(:agent_run, :failed, project: project,
        error_message: "DNS failure", stale_requeue_count: 1)

      activity.execute(agent_run_id: agent_run.id)

      expect(agent_run.reload.stale_requeue_count).to eq(2)
    end

    it "creates a system log entry" do
      agent_run = create(:agent_run, :failed, project: project,
        error_message: "Failed to pull image postgres:16")

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to change(AgentRunLog, :count).by(1)

      log = agent_run.agent_run_logs.last
      expect(log.content).to include("Pre-runner infra failure requeued")
      expect(log.content).to include("1/3")
    end
  end
end
