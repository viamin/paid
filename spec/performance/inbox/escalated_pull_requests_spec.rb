# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::EscalatedPullRequests do
  # @spec OPERATOR-INBOX-002C
  it "keeps queries bounded by project count, not blocked-PR row count" do
    account = create(:account)
    project = create(:project, account: account)
    second_project = create(:project, account: account)
    create_list(:issue, 5, :pull_request,
      project: project,
      pr_review_phase: "escalated",
      pr_escalation_reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
      draft_review_count: 5)
    create_list(:issue, 5, :pull_request,
      project: second_project,
      pr_review_phase: "escalated",
      pr_escalation_reason: Issue::PR_ESCALATION_REASON_OPERATIONAL_FAILURES)

    # 1 list query + project/account/tenant_setting preloads + 1 batched
    # run-history query — independent of blocked-PR row count.
    query_count = count_queries { described_class.call(account: account) }

    expect(query_count).to eq(5)
  end

  # @spec OPERATOR-INBOX-002C
  it "pushes an authorized project filter into the blocked-PR query" do
    account = create(:account)
    project = create(:project, account: account)
    other_project = create(:project, account: account)
    create(:issue, :pull_request,
      project: project,
      pr_review_phase: "escalated",
      pr_escalation_reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
      draft_review_count: 5)
    create_list(:issue, 5, :pull_request,
      project: other_project,
      pr_review_phase: "escalated",
      pr_escalation_reason: Issue::PR_ESCALATION_REASON_FAILURE_STREAK,
      draft_review_count: 5)

    queries = capture_queries { described_class.call(account:, project_ids: [ project.id ]) }
    blocked_pr_query = queries.find { |sql| sql.include?("FROM \"issues\" INNER JOIN \"projects\"") }

    expect(blocked_pr_query).to include("\"issues\".\"project_id\"")
  end
end
