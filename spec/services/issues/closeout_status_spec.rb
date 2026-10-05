# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::CloseoutStatus do # @spec PARTIAL-CLOSEOUT-002
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }

  def merged_partial_pr(number:)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: issue.id,
      created_at: 2.days.ago
    )
  end

  it "marks an issue with merged partial evidence stalled and explains the exact reason" do
    merged_partial_pr(number: 12)

    status = described_class.call(issue)

    expect(status.stalled?).to be(true)
    expect(status.reason).to include("merged")
    expect(status.reason).to include("#12")
    expect(status.evidence.merged_prs.map(&:number)).to contain_exactly(12)
  end

  it "reports the recorded completion outcome for no-code evidence" do
    issue.update!(paid_state: "completed", no_code_required_at: 3.hours.ago)

    status = described_class.call(issue.reload)

    expect(status.stalled?).to be(true)
    expect(status.evidence.no_code_required_at).to be_present
    expect(status.outcome).to include("no code required")
  end

  it "lists unresolved prerequisites blocking continuation" do
    merged_partial_pr(number: 12)
    blocker = create(:issue, project: project, github_state: "open", github_number: 44)
    create(:issue_dependency, issue: issue, depends_on_issue: blocker)

    status = described_class.call(issue)

    expect(status.unresolved_prerequisites).to include("#44")
  end

  it "is not stalled without closeout evidence" do
    status = described_class.call(issue)

    expect(status.stalled?).to be(false)
    expect(status.reason).to be_present
  end

  it "is not stalled while an open continuation request authorizes the issue" do
    merged_partial_pr(number: 12)
    create(:issue_continuation_request, issue: issue, project: project)

    expect(described_class.call(issue.reload).stalled?).to be(false)
  end

  it "is not stalled when resolved complete against the current evidence generation" do
    merged_partial_pr(number: 12)
    issue.update!(
      closeout_resolved_at: 1.hour.ago,
      closeout_resolution_digest: described_class.call(issue).evidence.digest,
      closeout_resolved_by_id: create(:user, account: account).id
    )

    expect(described_class.call(issue.reload).stalled?).to be(false)
  end

  it "is stalled again after a resolution when newer terminal evidence arrives" do
    merged_partial_pr(number: 12)
    issue.update!(
      closeout_resolved_at: 3.days.ago,
      closeout_resolution_digest: described_class.call(issue).evidence.digest,
      closeout_resolved_by_id: create(:user, account: account).id
    )
    merged_partial_pr(number: 13)

    expect(described_class.call(issue.reload).stalled?).to be(true)
  end
end
