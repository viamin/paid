# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::Analyze do
  def analysis_output(snapshot)
    remaining_edges = snapshot.fetch("effective_edges").drop(1)
      .map { |edge| edge.slice("from_issue_id", "to_issue_id") }
    {
      "summary" => "Review both declarations before changing either one.",
      "candidates" => [ {
        "declaration_changes" => [ { "edge_id" => snapshot.fetch("effective_edges").first.fetch("id"), "action" => "remove" } ],
        "evidence" => [ "Issue intent makes the declaration obsolete." ],
        "tradeoffs" => [ "Work may become eligible sooner." ],
        "missing_or_conflicting_intent" => [],
        "resulting_graph" => { "issue_ids" => snapshot.fetch("issues").pluck("id"), "edges" => remaining_edges },
        "acyclic" => true
      } ]
    }
  end

  def harness_response(snapshot:, output: analysis_output(snapshot).to_json, exit_code: 0, error: nil)
    AgentHarness::Response.new(output:, exit_code:, error:, duration: 1.0, provider: :codex)
  end

  def snapshot_for(cycle)
    CycleAnalyses::Snapshot.call(cycle:)
  end

  def stub_comments(comments)
    stub_request(:get, %r{api.github.com/repos/.*/issues/\d+/comments})
      .to_return(status: 200, body: comments.to_json, headers: { "Content-Type" => "application/json" })
  end

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
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot_for(cycle) })
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    llm = class_double(Llm::Request)
    allow(llm).to receive(:call).and_return(harness_response(snapshot:))
    stub_comments([])

    result = described_class.call(agent_run: run, llm:)

    expect(llm).to have_received(:call) { |prompt:, **| expect(prompt).to include("effective_edges", "Implementation phase", "unavailable_provenance_edge_ids") }
    expect(result).to include("recommendation" => analysis_output(snapshot), "graph_revision" => cycle.graph_revision)
  end

  it "caps issue and trusted-comment content in the prompt" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    limit = Prompts::BuildForIssue::DEFAULT_MAX_COMMENT_LENGTH
    first = create(:issue, project:, github_state: "open", body: "a" * (limit + 1))
    second = create(:issue, project:, github_state: "open", body: "short")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot_for(cycle) })
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    comment = { user: { login: "viamin" }, body: "b" * (limit + 1), html_url: "https://example.test/comment" }
    stub_comments([ comment ])
    llm = class_double(Llm::Request)
    allow(llm).to receive(:call).and_return(harness_response(snapshot:))

    described_class.call(agent_run: run, llm:)

    expect(llm).to have_received(:call) do |prompt:, **|
      expect(prompt).to include("a" * limit, "b" * limit)
      expect(prompt).not_to include("a" * (limit + 1), "b" * (limit + 1))
    end
  end

  # @spec AUTO-PICK-QUEUE-017 AUTO-PICK-QUEUE-019
  it "analyzes the persisted snapshot after the live graph changes" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open", body: "Captured first body")
    second = create(:issue, project:, github_state: "open", body: "Captured second body")
    edge = create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot_for(cycle) })
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    edge.destroy!
    stub_comments([])
    llm = class_double(Llm::Request, call: harness_response(snapshot:))

    result = described_class.call(agent_run: run, llm:)

    expect(llm).to have_received(:call) { |prompt:, **| expect(prompt).to include("Captured first body", edge.id.to_s) }
    expect(result.fetch("graph_revision")).to eq(cycle.graph_revision)
  end

  # @spec AUTO-PICK-QUEUE-017
  it "marks issue content unavailable when trusted comments cannot be fetched" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open", body: "Available local body")
    second = create(:issue, project:, github_state: "open", body: "Another local body")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot_for(cycle) })
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    stub_request(:get, %r{api.github.com/repos/.*/issues/\d+/comments}).to_return(status: 503)
    llm = class_double(Llm::Request, call: harness_response(snapshot:))

    result = described_class.call(agent_run: run, llm:)

    expect(result.dig("coverage", "unavailable_content_issue_ids")).to contain_exactly(first.id, second.id)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "rejects a successful harness response without the required recommendation structure" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot_for(cycle) })
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    stub_comments([])
    llm = class_double(Llm::Request, call: harness_response(snapshot:, output: "recommendation"))

    expect { described_class.call(agent_run: run, llm:) }
      .to raise_error(CycleAnalyses::InvalidResponse, /valid JSON/)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "rejects an unsuccessful harness response" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot_for(cycle) })
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    stub_comments([])
    llm = class_double(Llm::Request, call: harness_response(snapshot:, exit_code: 1, error: "runner failed"))

    expect { described_class.call(agent_run: run, llm:) }
      .to raise_error(AgentHarness::CommandExecutionError, "Cycle analysis failed: runner failed")
  end
end
