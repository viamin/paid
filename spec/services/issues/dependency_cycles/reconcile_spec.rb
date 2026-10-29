# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::DependencyCycles::Reconcile do
  # @spec DEPENDENCY-CYCLES-001 DEPENDENCY-CYCLES-002 DEPENDENCY-CYCLES-004
  it "persists one stable occurrence for a mutual cycle and resolves it after synchronization" do
    account = create(:account)
    project = create(:project, account: account)
    first = create(:issue, project: project, github_state: "open", paid_state: "new")
    second = create(:issue, project: project, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: first, depends_on_issue: second)
    dependency = create(:issue_dependency, issue: second, depends_on_issue: first)

    described_class.call(account: account)

    occurrence = DependencyCycleOccurrence.active.sole
    expect(occurrence.details.fetch("members")).to contain_exactly(first.id, second.id)
    expect(occurrence.details.fetch("cycle_path").size).to eq(2)

    dependency.destroy!
    described_class.call(account: account)

    expect(occurrence.reload).not_to be_active
  end

  # @spec DEPENDENCY-CYCLES-001 DEPENDENCY-CYCLES-002
  it "uses resolved cross-project dependencies but isolates accounts" do
    account = create(:account)
    first_project = create(:project, account: account, owner: "org", name: "one")
    second_project = create(:project, account: account, owner: "org", name: "two")
    first = create(:issue, project: first_project, github_state: "open", paid_state: "new")
    second = create(:issue, project: second_project, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: first, depends_on_issue: nil, depends_on_owner: "org", depends_on_repo: "two", depends_on_number: second.github_number)
    create(:issue_dependency, issue: second, depends_on_issue: first)

    described_class.call(account: account)

    expect(DependencyCycleOccurrence.active.sole.details.fetch("members")).to contain_exactly(first.id, second.id)
  end
end
