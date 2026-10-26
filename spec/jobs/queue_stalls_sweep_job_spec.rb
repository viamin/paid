# frozen_string_literal: true

require "rails_helper"

# @spec QUEUE-DIAG-004 @spec QUEUE-DIAG-006 @spec QUEUE-DIAG-012
RSpec.describe QueueStallsSweepJob do
  let(:user) { create(:user) }
  let(:account) { user.account }
  let!(:project) do
    create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true)
  end

  describe "#perform" do
    it "sweeps the account and records the outcome" do
      create(:issue, project: project, github_state: "open", paid_state: "new")

      described_class.perform_now(account_id: account.id)

      expect(Issue.find_by(project: project).agent_runs.count).to eq(1)
    end

    it "does not sweep another tenant's account" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_project = create(:project, account: other_account, created_by: other_user,
        auto_pick_enabled: true, active: true)
      other_issue = create(:issue, project: other_project, github_state: "open", paid_state: "new")

      described_class.perform_now(account_id: account.id)

      expect(other_issue.agent_runs.reload.count).to eq(0)
    end

    it "scopes the sweep to a single project when one is named" do
      other_project = create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true)
      other_issue = create(:issue, project: other_project, github_state: "open", paid_state: "new")

      described_class.perform_now(account_id: account.id, project_id: project.id)

      expect(other_issue.agent_runs.reload.count).to eq(0)
    end
  end

  describe "the agent-run lifecycle event" do
    # @spec QUEUE-DIAG-004
    it "schedules a sweep when a run reaches a terminal status" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      run = create(:agent_run, :running, :automatic, project: project, issue: issue, goal: "create_pr")

      expect(described_class).to receive(:perform_later).with(account_id: account.id, project_id: project.id)

      run.update!(status: "completed", completed_at: Time.current)
    end

    # @spec QUEUE-DIAG-004
    it "repairs a missed event through the periodic sweep" do
      create(:issue, project: project, github_state: "open", paid_state: "new")

      described_class.perform_now(account_id: account.id)

      expect(Issue.find_by(project: project).agent_runs.count).to eq(1)
    end
  end
end
