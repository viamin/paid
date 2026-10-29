# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseoutAcceptanceAuditSweepJob do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner, auto_pick_enabled: true) }

  # @spec PARTIAL-CLOSEOUT-037
  it "finds merged closeouts missed before PR merge and queues report-only audits" do
    issue = create(:issue, project:, github_state: "open", paid_state: "recommend_close")
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 12,
      github_state: "closed", pr_review_phase: "merged")

    described_class.perform_now

    expect(issue.agent_runs.pluck(:goal)).to eq([ "analyze_issue" ])
  end
end
