# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestIssueContinuation do # @spec PARTIAL-CLOSEOUT-007
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account, created_by: user, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }
  let(:merged_pr) do
    create(:issue, :pull_request, project: project, github_number: 71, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: issue.id, created_at: 2.days.ago)
  end

  before { merged_pr }

  describe ".write_operation?" do
    it "is a write operation" do
      expect(described_class.write_operation?).to be(true)
    end
  end

  describe "#call" do
    it "queues one continuation run through the same service as the inbox action" do
      result = tool.call(project_id: project.id, issue_id: issue.id, reason: "Audit the deferred remainder.", confirmed: true)

      request = IssueContinuationRequest.open_for_issue(issue)
      expect(request.requested_by).to eq(user)
      expect(result[:request_id]).to eq(request.id)
      expect(result[:agent_run_id]).to eq(AgentRun.last.id)
      expect(AgentRun.last.continuation_request_id).to eq(request.id)
    end

    it "records the same audit event as the inbox action" do
      tool.call(project_id: project.id, issue_id: issue.id, reason: "Audit it.", confirmed: true)

      expect(account.account_activity_events.where(action: "issue.continuation_requested")).to exist
    end

    it "raises when not confirmed" do
      expect {
        tool.call(project_id: project.id, issue_id: issue.id, reason: "Audit it.", confirmed: false)
      }.to raise_error(ArgumentError, /Confirmation required/)
    end

    it "raises when the issue has no closeout evidence" do
      plain = create(:issue, project: project, github_state: "open")

      expect {
        tool.call(project_id: project.id, issue_id: plain.id, reason: "Audit it.", confirmed: true)
      }.to raise_error(ArgumentError, /no terminal closeout evidence/)
    end

    it "refuses cross-tenant projects" do
      other_account = create(:account)
      other_project = create(:project, account: other_account, owner: "acme", repo: "beta")

      expect {
        tool.call(project_id: other_project.id, issue_id: issue.id, reason: "Audit it.", confirmed: true)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
