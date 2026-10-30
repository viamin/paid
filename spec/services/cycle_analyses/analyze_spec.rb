# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::Analyze do
  # @spec AUTO-PICK-QUEUE-017 AUTO-PICK-QUEUE-018 AUTO-PICK-QUEUE-019
  it "sends the complete effective graph and unavailable provenance to the harness" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open", body: "Implementation phase")
    second = create(:issue, project:, github_state: "open", body: "Validation phase")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second, declaration_url: nil)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first, declaration_url: "https://example.test/edge")
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => { "occurrence" => cycle.occurrence, "graph_revision" => cycle.graph_revision } })
    llm = class_double(Llm::Request)
    allow(llm).to receive(:call).and_return(double(content: "reviewable recommendation"))

    result = described_class.call(agent_run: run, llm:)

    expect(llm).to have_received(:call) { |prompt:, **| expect(prompt).to include("effective_edges", "Implementation phase", "unavailable_provenance_edge_ids") }
    expect(result).to include("recommendation" => "reviewable recommendation", "graph_revision" => cycle.graph_revision)
  end
end
