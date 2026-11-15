# frozen_string_literal: true

require "rails_helper"

# @spec AGENT-RETRY-015 EAGER-QUEUE-018 PARTIAL-CLOSEOUT-045
RSpec.describe RetryFailedAutoPickCreatePrJob do
  let(:project) { create(:project, auto_pick_enabled: true) }

  describe "#perform" do
    it "re-enters normal issue admission once and records the replacement" do
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      original = create(:agent_run, :failed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true)

      expect {
        described_class.new.perform(original.id, 1)
      }.to change(AgentRun, :count).by(1)
        .and have_enqueued_job(ProcessRunQueueJob)

      successor = AgentRun.order(:id).last
      expect(original.reload.status).to eq("retried")
      expect(successor).to have_attributes(issue: issue, goal: "create_pr", auto_pick: true, status: "queued")
      expect(OrchestrationDecision.last.outputs["new_agent_run_id"]).to eq(successor.id)
    end

    it "does not replace an implementation attempt that recorded a pushed revision" do
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      original = create(:agent_run, :failed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, result_commit_sha: "a" * 40)

      expect {
        described_class.new.perform(original.id, 1)
      }.not_to change(AgentRun, :count)

      expect(original.reload.status).to eq("failed")
      expect(OrchestrationDecision.last.outputs["reason"]).to eq("implementation_work_produced")
    end

    it "does not replace an implementation attempt that recorded a pull request" do
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      original = create(:agent_run, :failed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 91)

      expect {
        described_class.new.perform(original.id, 1)
      }.not_to change(AgentRun, :count)

      expect(original.reload.status).to eq("failed")
      expect(OrchestrationDecision.last.outputs["reason"]).to eq("implementation_work_produced")
    end

    it "claims only one successor when a delayed job is delivered twice" do
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      original = create(:agent_run, :failed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true)

      2.times { described_class.new.perform(original.id, 1) }

      expect(AgentRun.where(project: project, issue: issue, goal: "create_pr", status: "queued").count).to eq(1)
      expect(OrchestrationDecision.where(agent_run: original).pluck(:outputs)).to include(hash_including("reason" => "not_failed"))
    end
  end
end
