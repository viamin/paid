# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Issues::ReleaseDependencyBlockedDependents do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:dependency) { create(:issue, project:, github_number: 4321, github_state: "open") }
  let(:dependent) do
    create(:issue, project:, github_number: 509, paid_state: "manual_review",
      manual_review_reason: "Paid's agent run completed and opened a pull request, but this issue remains open and is " \
        "#{Issue::DEPENDENCY_BLOCKED_REASON_MARKER}: #4321. This issue stays pending until the dependency resolves or a " \
        "human intervenes.")
  end

  before { create(:issue_dependency, issue: dependent, depends_on_issue: dependency) }

  # @spec MANUAL-REVIEW-RECOVERY-003
  it "returns the parked issue to the pipeline once the dependency resolves" do
    dependency.update!(github_state: "closed", closed_at: Time.current)

    described_class.call(dependency_issue: dependency)

    expect(dependent.reload.paid_state).to eq("completed")
    expect(dependent.manual_review_reason).to be_nil
    expect(dependent.manual_review_started_at).to be_nil
  end

  # @spec MANUAL-REVIEW-RECOVERY-003
  it "keeps the issue parked while another dependency is still unresolved" do
    other = create(:issue, project:, github_number: 4322, github_state: "open")
    create(:issue_dependency, issue: dependent, depends_on_issue: other)
    dependency.update!(github_state: "closed", closed_at: Time.current)

    described_class.call(dependency_issue: dependency)

    expect(dependent.reload.paid_state).to eq("manual_review")
    expect(dependent.manual_review_reason).to be_present
  end

  # @spec MANUAL-REVIEW-RECOVERY-003
  it "ignores an issue that is not parked on a dependency" do
    dependent.update!(manual_review_reason: "Round limit reached.")
    dependency.update!(github_state: "closed", closed_at: Time.current)

    described_class.call(dependency_issue: dependency)

    expect(dependent.reload.paid_state).to eq("manual_review")
  end

  # @spec MANUAL-REVIEW-RECOVERY-003
  it "releases the dependent when the dependency closes through the GitHub sync" do
    github_issue = OpenStruct.new(
      id: dependency.github_issue_id,
      number: dependency.github_number,
      title: dependency.title,
      body: dependency.body,
      html_url: dependency.github_html_url,
      state: "closed",
      labels: [],
      pull_request: nil,
      state_reason: "completed",
      user: OpenStruct.new(login: "viamin"),
      created_at: dependency.github_created_at,
      updated_at: Time.current
    )

    Issues::UpsertFromGithub.call(project:, github_issue:)

    expect(dependent.reload.paid_state).to eq("completed")
  end
end
