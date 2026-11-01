# frozen_string_literal: true

require "rails_helper"

RSpec.describe Rdr075DependencyCycleFixture do
  # @spec AUTO-PICK-QUEUE-014 AUTO-PICK-QUEUE-015 AUTO-PICK-QUEUE-019
  it "reproduces the provenance-free three-issue cycle and its live repair declaration" do
    fixture = create_rdr_075_dependency_cycle_fixture

    cycle = Issues::DependencyCycles.call(account: fixture.user.account).sole

    expect(cycle.issues.map(&:github_number)).to contain_exactly(4334, 4635, 4604)
    expect(cycle.effective_edges.map { |edge| [ edge.from_id, edge.to_id ] }).to match_array(
      fixture.dependencies.map { |dependency| [ dependency.issue_id, dependency.depends_on_issue_id ] }
    )
    expect(fixture.dependencies.map(&:declaration_url)).to all(be_nil)
    expect(fixture.issues.fetch(:tool_validation).body).to include("Depends on #4334")
  end

  # @spec AUTO-PICK-QUEUE-014 AUTO-PICK-QUEUE-015
  it "does not synthesize a cycle after one member becomes terminal" do
    fixture = create_rdr_075_dependency_cycle_fixture
    fixture.issues.fetch(:tool_validation).update!(paid_state: "completed")

    expect(Issues::DependencyCycles.call(account: fixture.user.account)).to be_empty
    expect(IssueDependency.where(id: fixture.dependencies.map(&:id)).count).to eq(3)
  end
end
