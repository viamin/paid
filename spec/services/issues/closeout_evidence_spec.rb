# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::CloseoutEvidence do # @spec PARTIAL-CLOSEOUT-001
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project: project, github_state: "open") }

  def merged_pr(project:, number:, parent_issue_id: nil, created_at: 2.days.ago, **attrs)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: parent_issue_id,
      created_at: created_at,
      **attrs
    )
  end

  def open_pr(project:, number:, github_html_url: nil)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: number,
      github_state: "open",
      pr_review_phase: "ready",
      github_html_url: github_html_url
    )
  end

  def completed_create_pr_run(project:, issue:, number:, url:)
    create(
      :agent_run,
      :completed,
      project: project,
      issue: issue,
      goal: "create_pr",
      pull_request_number: number,
      pull_request_url: url
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
    completed_create_pr_run(project: project, issue: issue, number: 55,
      url: "https://github.com/acme/alpha/pull/55")

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

  it "ignores an upstream-synced merged PR that collides in number with the run's unmerged fork PR" do
    # GitHub PR numbers are per-repo, so a fork PR and an upstream-synced PR
    # can share a github_number in the same project. The run's persisted
    # pull_request_url must match the merged PR it is supposed to be evidence
    # for; the upstream PR's merge cannot mark the run's open fork PR as
    # terminal closeout evidence (#4130 review).
    merged_pr(project: project, number: 99,
      source: Issue::UPSTREAM_PULL_REQUEST_SOURCE,
      github_html_url: "https://github.com/upstream/repo/pull/99")
    completed_create_pr_run(project: project, issue: issue, number: 99,
      url: "https://github.com/acme/alpha/pull/99")

    expect(described_class.call(issue).present?).to be(false)
  end

  it "matches via the null-URL fallback when github_html_url is not yet synced" do
    # Same repo-qualified URL fallback as
    # Issue.paid_generated_pull_request_source_issue_ids: a PR row whose
    # github_html_url has not been hydrated yet still correlates to a run
    # whose pull_request_url equals the project owner/repo URL constructed
    # from the project row (#4130 review).
    merged_pr(project: project, number: 77)
    completed_create_pr_run(project: project, issue: issue, number: 77,
      url: "https://github.com/acme/alpha/pull/77")

    result = described_class.call(issue)

    expect(result.merged_prs.map(&:number)).to contain_exactly(77)
  end

  it "does not fabricate terminal evidence from an unrelated upstream PR when the run's fork PR is open" do
    # The exact hazard called out in #4130's review: a run on the project's
    # fork produces PR #42, but PR #42 is also an upstream-synced PR that
    # is merged. Without URL correlation the number-only join treats the
    # upstream merge as terminal evidence for the source issue and
    # ResolveCloseout would mark the open issue closed via MCP.
    open_pr(project: project, number: 42,
      github_html_url: "https://github.com/acme/alpha/pull/42")
    merged_pr(project: project, number: 42,
      source: Issue::UPSTREAM_PULL_REQUEST_SOURCE,
      github_html_url: "https://github.com/upstream/repo/pull/42")
    completed_create_pr_run(project: project, issue: issue, number: 42,
      url: "https://github.com/acme/alpha/pull/42")

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
