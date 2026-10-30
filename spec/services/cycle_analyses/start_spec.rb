# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::Start do
  # @spec AUTO-PICK-QUEUE-016 AUTO-PICK-QUEUE-017
  it "starts occurrences whose CRC exceeds PostgreSQL's signed integer range and persists prompt evidence" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    create(:runner, user:, enabled_for_agent_runs: true)
    first = create(:issue, project:, github_state: "open", body: "First body")
    second = create(:issue, project:, github_state: "open", body: "Second body")
    first_edge = create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    second_edge = create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    occurrence = (1..).lazy.map { |suffix| "#{cycle.occurrence}:#{suffix}" }
      .find { |candidate| Zlib.crc32(candidate) > 2_147_483_647 }
    cycle = cycle.with(occurrence:)

    result = described_class.call(cycle:, actor: user)

    expect(result).to be_success
    snapshot = result.agent_run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    expect(snapshot.fetch("issues").pluck("id", "body")).to contain_exactly(
      [ first.id, "First body" ], [ second.id, "Second body" ]
    )
    expect(snapshot.fetch("effective_edges").pluck("id")).to contain_exactly(first_edge.id, second_edge.id)
  end
end
