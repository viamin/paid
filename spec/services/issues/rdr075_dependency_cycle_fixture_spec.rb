# frozen_string_literal: true

require "rails_helper"

RSpec.describe Rdr075DependencyCycleFixture do
  def analysis_response(snapshot)
    edge = snapshot.fetch("effective_edges").first
    {
      "summary" => "Review the cycle declarations before changing them.",
      "candidates" => [ {
        "declaration_changes" => [ { "edge_id" => edge.fetch("id"), "action" => "remove" } ],
        "evidence" => [ "The captured declaration is available in the issue body." ],
        "tradeoffs" => [ "Removing the edge changes issue ordering." ],
        "missing_or_conflicting_intent" => [],
        "resulting_graph" => {
          "issue_ids" => snapshot.fetch("issues").pluck("id"),
          "edges" => snapshot.fetch("effective_edges").drop(1)
            .map { |candidate| candidate.slice("from_issue_id", "to_issue_id") }
        },
        "acyclic" => true
      } ]
    }
  end

  def successful_response(snapshot)
    AgentHarness::Response.new(output: analysis_response(snapshot).to_json, exit_code: 0, error: nil,
      duration: 1.0, provider: :codex)
  end

  def stub_issue_comments
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/.*/issues/\d+/comments(?:\?.*)?\z})
      .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
  end

  def analyze_cycle(fixture, cycle)
    snapshot = CycleAnalyses::Snapshot.call(cycle:)
    run = create(:agent_run, project: fixture.project, initiating_user: fixture.user,
      goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot })
    llm = class_double(Llm::Request)
    allow(llm).to receive(:call).and_return(successful_response(snapshot))
    stub_issue_comments
    [ CycleAnalyses::Analyze.call(agent_run: run, llm:), llm ]
  end

  # @spec AUTO-PICK-QUEUE-014 AUTO-PICK-QUEUE-015 AUTO-PICK-QUEUE-017 AUTO-PICK-QUEUE-018 AUTO-PICK-QUEUE-019
  it "sends the provenance-free cycle and live repair declaration through analysis" do
    fixture = create_rdr_075_dependency_cycle_fixture

    cycle = Issues::DependencyCycles.call(account: fixture.user.account).sole
    result, llm = analyze_cycle(fixture, cycle)

    expect(cycle.issues.map(&:github_number)).to contain_exactly(4334, 4635, 4604)
    expect(cycle.effective_edges.map { |edge| [ edge.from_id, edge.to_id ] }).to match_array(
      fixture.dependencies.map { |dependency| [ dependency.issue_id, dependency.depends_on_issue_id ] }
    )
    expect(fixture.dependencies.map(&:declaration_url)).to all(be_nil)
    expect(result.dig("coverage", "unavailable_provenance_edge_ids")).to match_array(
      fixture.dependencies.map(&:id)
    )
    expect(llm).to have_received(:call) do |prompt:, **|
      expect(prompt).to include("Depends on #4334")
    end
  end

  # @spec AUTO-PICK-QUEUE-014 AUTO-PICK-QUEUE-015
  it "does not synthesize a cycle after one member becomes terminal" do
    fixture = create_rdr_075_dependency_cycle_fixture
    fixture.issues.fetch(:tool_validation).update!(paid_state: "completed")

    expect(Issues::DependencyCycles.call(account: fixture.user.account)).to be_empty
    expect(IssueDependency.where(id: fixture.dependencies.map(&:id)).count).to eq(3)
  end
end
