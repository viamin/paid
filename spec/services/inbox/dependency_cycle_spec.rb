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
    create(:issue_dependency, issue: second, depends_on_issue: first)

    entries = described_class.call(user:, kind: described_class::DEPENDENCY_CYCLE_KIND)

    expect(entries).to contain_exactly(have_attributes(
      id: a_string_starting_with("dependency_cycle:"), record: have_attributes(issues: contain_exactly(first, second))
    ))
  end
end
