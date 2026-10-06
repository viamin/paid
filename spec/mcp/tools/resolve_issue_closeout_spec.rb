# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ResolveIssueCloseout do # @spec PARTIAL-CLOSEOUT-007
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account, created_by: user, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }
  let(:merged_pr) do
    create(:issue, :pull_request, project: project, github_number: 81, github_state: "closed",
      pr_review_phase: "merged", parent_issue_id: issue.id, created_at: 2.days.ago)
  end

  before { merged_pr }

  describe ".write_operation?" do
    it "is a write operation" do
      expect(described_class.write_operation?).to be(true)
    end
  end

  describe "#call" do
    it "resolves the issue complete against the recorded evidence with the same audit as the inbox action" do
      result = tool.call(project_id: project.id, issue_id: issue.id, reason: "Merged PR #81 covers it.", confirmed: true)

      issue.reload
      expect(result[:status]).to eq("completed")
      expect(issue.paid_state).to eq("completed")
      expect(issue.closeout_resolved_by).to eq(user)
      expect(account.account_activity_events.where(action: "issue.closeout_resolved")).to exist
    end

    it "raises when not confirmed" do
      expect {
        tool.call(project_id: project.id, issue_id: issue.id, reason: "Done.", confirmed: false)
      }.to raise_error(ArgumentError, /Confirmation required/)
    end

    it "raises when the issue has no closeout evidence" do
      plain = create(:issue, project: project, github_state: "open")

      expect {
        tool.call(project_id: project.id, issue_id: plain.id, reason: "Done.", confirmed: true)
      }.to raise_error(ArgumentError, /no terminal closeout evidence/)
    end
  end
end
