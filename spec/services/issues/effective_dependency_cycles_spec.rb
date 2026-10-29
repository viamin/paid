# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::EffectiveDependencyCycles do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  # @spec DEPENDENCY-CYCLE-001
  it "returns one cycle with its concrete path and downstream held work" do
    first = create(:issue, project:, github_state: "open", paid_state: "new")
    second = create(:issue, project:, github_state: "open", paid_state: "new")
    downstream = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: first, depends_on_issue: second)
    create(:issue_dependency, issue: second, depends_on_issue: first)
    create(:issue_dependency, issue: downstream, depends_on_issue: first)

    cycle = described_class.call(account:).sole

    expect(cycle.issues).to contain_exactly(first, second)
    expect(cycle.edges.map { |edge| [ edge.from, edge.to ] }).to eq([ [ first, second ], [ second, first ] ])
    expect(cycle.downstream_issues).to contain_exactly(downstream)
  end

  # @spec DEPENDENCY-CYCLE-001
  it "does not mistake nonblocking targets or parent references for a cycle" do
    parent = create(:issue, project:, github_state: "open", paid_state: "new")
    child = create(:issue, project:, parent_issue: parent, github_state: "open", paid_state: "new")
    parked = create(:issue, project:, github_state: "open", paid_state: "completed")
    create(:issue_dependency, issue: child, depends_on_issue: parent)
    create(:issue_dependency, issue: parent, depends_on_issue: child)
    create(:issue_dependency, issue: child, depends_on_issue: parked)

    expect(described_class.call(account:)).to be_empty
  end

  # @spec DEPENDENCY-CYCLE-001
  it "finds a resolved cross-project cycle" do
    other_project = create(:project, account:)
    first = create(:issue, project:, github_state: "open", paid_state: "new")
    second = create(:issue, project: other_project, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: first, depends_on_issue: nil, depends_on_owner: other_project.owner, depends_on_repo: other_project.repo,
      depends_on_number: second.github_number)
    create(:issue_dependency, issue: second, depends_on_issue: first)

    expect(described_class.call(account:).sole.issues).to contain_exactly(first, second)
  end
end
