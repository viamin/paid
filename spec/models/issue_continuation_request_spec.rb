# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueContinuationRequest do # @spec PARTIAL-CLOSEOUT-003 @spec PARTIAL-CLOSEOUT-009
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project, github_state: "open") }
  let(:user) { create(:user, account: account) }

  it "persists actor, reason, and evidence generation identity" do
    request = create(
      :issue_continuation_request,
      issue: issue,
      project: project,
      requested_by: user,
      reason: "Follow-up work was never filed; audit the remainder.",
      evidence: { "merged_prs" => [ { "number" => 12 } ] },
      evidence_digest: "abc123"
    )

    expect(request.requested_by).to eq(user)
    expect(request.reason).to be_present
    expect(request.evidence_digest).to eq("abc123")
    expect(request).to be_open
    expect(request.status).to eq("queued")
  end

  it "allows only one open request per issue across concurrent requests" do
    create(:issue_continuation_request, issue: issue, project: project, requested_by: user)

    expect {
      create(:issue_continuation_request, issue: issue, project: project, requested_by: user)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows a new request after the previous one closed" do
    create(:issue_continuation_request, :consumed, issue: issue, project: project, requested_by: user)

    expect {
      create(:issue_continuation_request, issue: issue, project: project, requested_by: user)
    }.not_to raise_error
  end

  it "closes as consumed when its run reaches a terminal status" do
    request = create(:issue_continuation_request, issue: issue, project: project, requested_by: user)
    run = create(:agent_run, :queued, project: project, issue: issue, goal: "create_pr",
      trigger_type: "manual", continuation_request: request)

    run.cancel!(error: "operator cancelled")

    expect(request.reload.status).to eq("consumed")
    expect(request.closed_at).to be_present
    expect(request.closure_reason).to include("cancelled")
  end

  describe ".open_for_issue" do
    it "returns the open request and ignores closed ones" do
      open_request = create(:issue_continuation_request, issue: issue, project: project, requested_by: user)
      create(:issue_continuation_request, :superseded,
        issue: create(:issue, project: project), project: project, requested_by: user)

      expect(described_class.open_for_issue(issue)).to eq(open_request)
    end
  end
end
