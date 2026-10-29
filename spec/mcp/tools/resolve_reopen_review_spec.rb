# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ResolveReopenReview do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:session) { create(:chat_session, account:, created_by: user) }
  let(:tool) { described_class.new(user:, session:) }
  let(:project) { create(:project, account:, created_by: user, owner: "acme", repo: "alpha") }
  let(:issue) do
    create(:issue, project:, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      github_updated_at: Time.current.change(usec: 0))
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "is available through MCP as a confirmed write operation" do
    expect(described_class).to be_write_operation
    expect(described_class).to be_mcp_available
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "records the authenticated operator's current-revision decision through MCP without creating a run" do
    expect {
      result = Tools::Registry.dispatch_mcp(
        name: described_class.tool_name,
        arguments: {
          project_id: project.id, issue_id: issue.id,
          reason: "The reopened scope still needs current validation.", revision: issue.github_updated_at.iso8601, confirmed: true
        },
        user:, session:
      )

      expect(result).to include(issue_id: issue.id, status: "new")
    }.not_to change(AgentRun, :count)

    expect(issue.reload.paid_state).to eq("new")
    expect(AccountActivityEvent.last).to have_attributes(actor: user, subject: issue)
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "requires confirmation and preserves a stale reopen hold" do
    expect {
      tool.call(project_id: project.id, issue_id: issue.id,
        reason: "The reopened scope still needs current validation.", revision: issue.github_updated_at.iso8601)
    }.to raise_error(ArgumentError, /Confirmation required/)

    expect {
      tool.call(project_id: project.id, issue_id: issue.id,
        reason: "The reopened scope still needs current validation.", revision: "stale", confirmed: true)
    }.to raise_error(ArgumentError, /changed after this review/)

    expect(issue.reload).to be_reopen_review_pending
  end
end
