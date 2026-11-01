# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::ApplyRepair do
  def analysis_recommendation(snapshot)
    remaining_edges = snapshot.fetch("effective_edges").drop(1)
      .map { |edge| edge.slice("from_issue_id", "to_issue_id") }
    {
      "summary" => "Remove obsolete declaration.",
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

  def analysis_recommendation_for_edge(snapshot, edge_id)
    remaining_edges = snapshot.fetch("effective_edges")
      .reject { |e| e["id"] == edge_id }
      .map { |edge| edge.slice("from_issue_id", "to_issue_id") }
    {
      "summary" => "Remove obsolete declaration.",
      "candidates" => [ {
        "declaration_changes" => [ { "edge_id" => edge_id, "action" => "remove" } ],
        "evidence" => [ "Issue intent makes the declaration obsolete." ],
        "tradeoffs" => [ "Work may become eligible sooner." ],
        "missing_or_conflicting_intent" => [],
        "resulting_graph" => { "issue_ids" => snapshot.fetch("issues").pluck("id"), "edges" => remaining_edges },
        "acyclic" => true
      } ]
    }
  end

  def snapshot_for(cycle)
    CycleAnalyses::Snapshot.call(cycle:)
  end

  # When repair is applied to a declaration from an admitted comment, the system SHALL
  # fetch the live GitHub comment and apply the declared change.
  it "applies repair to a declaration from an admitted comment" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open", body: "Implementation phase")
    second = create(:issue, project:, github_state: "open", body: "Validation phase")
    edge = create_legacy_issue_dependency(issue: first, depends_on_issue: second,
      declaration_source: "comment", declaration_url: "https://github.com/test/repo/issues/1#issuecomment-12345")
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot_for(cycle) })

    # Find the snapshot edge that corresponds to our test edge
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    comment_edge_in_snapshot = snapshot.fetch("effective_edges").find do |e|
      e["declaration_source"] == "comment"
    end

    recommendation = analysis_recommendation_for_edge(snapshot, comment_edge_in_snapshot["id"])
    parsed_recommendation = CycleAnalyses::Response.parse(recommendation.to_json,
      snapshot: snapshot)

    # Mock the GitHub comment
    comment_body = "This issue depends on ##{second.github_number}"
    stub_request(:get, "https://api.github.com/repos/#{project.full_name}/issues/comments/12345")
      .to_return(status: 200, body: { id: 12345, body: comment_body }.to_json,
        headers: { "Content-Type" => "application/json" })
    updated_comment_body = "This issue depends on nothing"
    stub_request(:patch, "https://api.github.com/repos/#{project.full_name}/issues/comments/12345")
      .to_return(status: 200, body: { id: 12345, body: updated_comment_body }.to_json,
        headers: { "Content-Type" => "application/json" })

    result = described_class.call(cycle:, actor: user, recommendation: parsed_recommendation, snapshot:)

    expect(result.status).to eq("applied")
    expect(result.mutations[comment_edge_in_snapshot["id"].to_s]).to include("action" => "remove")
    expect(WebMock).to have_requested(:patch, "https://api.github.com/repos/#{project.full_name}/issues/comments/12345")
  end

  # When the graph has changed (staleness check), the repair SHALL be rejected.
  it "rejects repair when the graph has changed since the recommendation" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open", body: "Implementation phase")
    second = create(:issue, project:, github_state: "open", body: "Validation phase")
    edge = create_legacy_issue_dependency(issue: first, depends_on_issue: second,
      declaration_source: "comment")
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot_for(cycle) })
    recommendation = analysis_recommendation(run.external_metadata.fetch(CycleAnalyses::METADATA_KEY))
    parsed_recommendation = CycleAnalyses::Response.parse(recommendation.to_json,
      snapshot: run.external_metadata.fetch(CycleAnalyses::METADATA_KEY))

    # Remove the edge to make the graph stale
    edge.destroy!

    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    expect { described_class.call(cycle:, actor: user, recommendation: parsed_recommendation, snapshot:) }
      .to raise_error("The dependency cycle graph has changed since the recommendation was generated")
  end

  # When the actor lacks authority to repair the issue, the repair SHALL be rejected.
  it "rejects repair when the actor lacks authority" do
    user = create(:user)
    other_user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open", body: "Implementation phase")
    second = create(:issue, project:, github_state: "open", body: "Validation phase")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot_for(cycle) })
    recommendation = analysis_recommendation(run.external_metadata.fetch(CycleAnalyses::METADATA_KEY))
    parsed_recommendation = CycleAnalyses::Response.parse(recommendation.to_json,
      snapshot: run.external_metadata.fetch(CycleAnalyses::METADATA_KEY))

    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    expect { described_class.call(cycle:, actor: other_user, recommendation: parsed_recommendation, snapshot:) }
      .to raise_error("Actor is not a member of the account owning the cycle")
  end

  # When repair cannot fetch the live comment, the repair SHALL fail gracefully.
  it "handles failure to fetch the live GitHub comment" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open", body: "Implementation phase")
    second = create(:issue, project:, github_state: "open", body: "Validation phase")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second,
      declaration_source: "comment", declaration_url: "https://github.com/test/repo/issues/1#issuecomment-12345")
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => snapshot_for(cycle) })
    recommendation = analysis_recommendation(run.external_metadata.fetch(CycleAnalyses::METADATA_KEY))
    parsed_recommendation = CycleAnalyses::Response.parse(recommendation.to_json,
      snapshot: run.external_metadata.fetch(CycleAnalyses::METADATA_KEY))

    # Mock failed comment fetch
    stub_request(:get, "https://api.github.com/repos/#{project.full_name}/issues/comments/12345")
      .to_return(status: 404)

    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    expect { described_class.call(cycle:, actor: user, recommendation: parsed_recommendation, snapshot:) }
      .to raise_error(GithubClient::Error)
  end
end
