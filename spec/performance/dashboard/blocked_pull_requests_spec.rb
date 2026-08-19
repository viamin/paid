# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::BlockedPullRequests do
  # @spec PR-ESCALATION-011
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
end
