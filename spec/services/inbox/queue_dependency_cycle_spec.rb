# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::Queue do
  # @spec AUTO-PICK-QUEUE-015
  it "surfaces one stable accessible Inbox occurrence for a cycle" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")
    create(:issue_dependency, issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)

    entries = described_class.call(user:, kind: described_class::DEPENDENCY_CYCLE_KIND)

    expect(entries).to contain_exactly(have_attributes(
      id: a_string_starting_with("dependency_cycle:"), record: have_attributes(issues: contain_exactly(first, second))
    ))
    expect(described_class.find_entry(user:, entry_id: entries.sole.id)).to have_attributes(id: entries.sole.id)
  end

  it "does not expose a cycle that includes another owner's project" do
    user = create(:user)
    other_user = create(:user, account: user.account)
    visible_project = create(:project, account: user.account, created_by: user)
    hidden_project = create(:project, account: user.account, created_by: other_user)
    visible_issue = create(:issue, project: visible_project, github_state: "open")
    hidden_issue = create(:issue, project: hidden_project, github_state: "open")
    create(:issue_dependency, issue: visible_issue, depends_on_issue: hidden_issue)
    create_legacy_issue_dependency(issue: hidden_issue, depends_on_issue: visible_issue)

    entries = described_class.call(user:, kind: described_class::DEPENDENCY_CYCLE_KIND)

    expect(entries).to be_empty
  end

  # @spec AUTO-PICK-QUEUE-015
  it "does not expose downstream work from another owner's project" do
    user = create(:user)
    other_user = create(:user, account: user.account)
    visible_project = create(:project, account: user.account, created_by: user)
    hidden_project = create(:project, account: user.account, created_by: other_user)
    first = create(:issue, project: visible_project, github_state: "open")
    second = create(:issue, project: visible_project, github_state: "open")
    visible_downstream = create(:issue, project: visible_project, github_state: "open")
    hidden_downstream = create(:issue, project: hidden_project, github_state: "open")
    create(:issue_dependency, issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    create(:issue_dependency, issue: visible_downstream, depends_on_issue: first)
    create(:issue_dependency, issue: hidden_downstream, depends_on_issue: visible_downstream)

    account_cycle = Issues::DependencyCycles.call(account: user.account).sole
    entry = described_class.call(user:, kind: described_class::DEPENDENCY_CYCLE_KIND).sole
    payload = Api::V1::InboxEntrySerializer.render(entry)

    expect(account_cycle.downstream_issues).to contain_exactly(visible_downstream, hidden_downstream)
    expect(entry.record.downstream_issues).to contain_exactly(visible_downstream)
    expect(entry.summary).to eq("1 downstream open issue remains held.")
    expect(payload.fetch(:downstream_issues_held)).to eq(1)
  end

  # @spec AUTO-PICK-QUEUE-016
  it "carries each path issue's title, labels, and umbrella parent context" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    parent = create(:issue, project:, title: "Ship the widget umbrella", github_number: 100)
    first = create(:issue, project:, github_state: "open", title: "First declares second",
      labels: [ "bug" ], parent_issue: parent)
    second = create(:issue, project:, github_state: "open", title: "Second declares first")
    create(:issue_dependency, issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)

    entry = described_class.call(user:, kind: described_class::DEPENDENCY_CYCLE_KIND).sole
    first_in_path = entry.record.path.find { |issue| issue.id == first.id }
    second_in_path = entry.record.path.find { |issue| issue.id == second.id }

    expect(first_in_path).to have_attributes(title: "First declares second", labels: [ "bug" ], parent_issue: parent)
    expect(second_in_path.parent_issue).to be_nil
  end

  # @spec AUTO-PICK-QUEUE-016
  it "redacts a path issue's umbrella context when the legacy parent's project is outside the viewer's authorized projects" do
    user = create(:user)
    other_user = create(:user, account: user.account)
    visible_project = create(:project, account: user.account, created_by: user)
    hidden_project = create(:project, account: user.account, created_by: other_user)
    hidden_parent = create(:issue, project: hidden_project, title: "Hidden umbrella")
    first = create(:issue, project: visible_project, github_state: "open")
    first.update_column(:parent_issue_id, hidden_parent.id)
    second = create(:issue, project: visible_project, github_state: "open")
    create(:issue_dependency, issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)

    entry = described_class.call(user:, kind: described_class::DEPENDENCY_CYCLE_KIND).sole

    expect(entry.record.path.find { |issue| issue.id == first.id }.parent_issue).to be_nil
  end

  # @spec AUTO-PICK-QUEUE-015
  it "surfaces a recreated cycle after the prior occurrence was personally removed" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")
    create(:issue_dependency, issue: first, depends_on_issue: second)
    removed_edge = create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    original_entry = described_class.call(user:, kind: described_class::DEPENDENCY_CYCLE_KIND).sole
    Inbox::Removals::Remove.call(entry: original_entry, user:)

    removed_edge.destroy!
    expect(described_class.call(user:, kind: described_class::DEPENDENCY_CYCLE_KIND)).to be_empty

    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    recreated_entry = described_class.call(user:, kind: described_class::DEPENDENCY_CYCLE_KIND).sole

    expect(recreated_entry.id).to eq(original_entry.id)
    expect(Inbox::RequestIdentity.occurrence_for(recreated_entry))
      .not_to eq(Inbox::RequestIdentity.occurrence_for(original_entry))
  end
end
