# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::CloseoutEvidence do # @spec PARTIAL-CLOSEOUT-001
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project: project, github_state: "open") }

  def merged_pr(project:, number:, parent_issue_id: nil, created_at: 2.days.ago)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: parent_issue_id,
      created_at: created_at
    )
  end

  it "reports no evidence for an untouched issue" do
    result = described_class.call(issue)

    expect(result.present?).to be(false)
    expect(result.merged_prs).to be_empty
    expect(result.no_code_required_at).to be_nil
  end

  it "collects a merged PR row linked via parent_issue_id" do
    pr = merged_pr(project: project, number: 12, parent_issue_id: issue.id)

    result = described_class.call(issue)

    expect(result.present?).to be(true)
    expect(result.merged_prs.map(&:number)).to contain_exactly(12)
    expect(result.merged_prs.first.url).to eq(pr.github_url)
    expect(result.terminal_at).to be_present
  end

  it "collects a merged PR matched via the originating run's pull_request_number" do
    merged_pr(project: project, number: 55)
    create(
      :agent_run,
      :completed,
      project: project,
      issue: issue,
      goal: "create_pr",
      pull_request_number: 55,
      pull_request_url: "https://github.com/acme/alpha/pull/55"
    )

    result = described_class.call(issue)

    expect(result.merged_prs.map(&:number)).to contain_exactly(55)
    expect(result.merged_prs.first.run_id).to be_present
  end

  it "ignores open or closed-unmerged PR rows" do
    create(:issue, :pull_request, project: project, github_number: 7, github_state: "open",
      pr_review_phase: "ready", parent_issue_id: issue.id)
    create(:issue, :pull_request, project: project, github_number: 8, github_state: "closed",
      pr_review_phase: "draft", parent_issue_id: issue.id)

    expect(described_class.call(issue).present?).to be(false)
  end

  it "includes a no-code-required declaration as terminal-run evidence" do
    issue.update!(no_code_required_at: 3.hours.ago)

    result = described_class.call(issue.reload)

    expect(result.present?).to be(true)
    expect(result.no_code_required_at).to be_present
  end

  it "produces a different digest when new terminal evidence arrives" do
    merged_pr(project: project, number: 12, parent_issue_id: issue.id)
    before = described_class.call(issue)

    merged_pr(project: project, number: 13, parent_issue_id: issue.id)
    after = described_class.call(issue)

    expect(after.digest).not_to eq(before.digest)
    expect(after.terminal_at).to be >= before.terminal_at
  end

  it "keeps the digest stable when nothing changed" do
    merged_pr(project: project, number: 12, parent_issue_id: issue.id)

    expect(described_class.call(issue).digest).to eq(described_class.call(issue.reload).digest)
  end
end
