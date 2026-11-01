# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::Repair do
  # @spec AUTO-PICK-QUEUE-019
  it "removes one uniquely matched live declaration when legacy provenance is absent" do
    _user, cycle, run = cycle_run
    source = cycle.path.first
    target = cycle.path.second
    client = instance_double(GithubClient)
    live = { body: "## Dependencies\nDepends on ##{target.github_number}\n\nKeep this text." }
    allow(client).to receive(:issue).and_return(live)
    allow(client).to receive(:update_issue)
    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "pending_sync", "changed_edge_ids" => [ cycle.path_edges.first.id ])
    expect(client).to have_received(:update_issue).with(source.project.full_name, source.github_number,
      body: "## Dependencies\n\nKeep this text.")
  end

  # @spec AUTO-PICK-QUEUE-019
  it "does not write when the live declaration is ambiguous or changed" do
    _user, cycle, run = cycle_run
    target = cycle.path.second
    client = instance_double(GithubClient, issue: { body: "Depends on ##{target.github_number}\nDepends on ##{target.github_number}" })
    allow(client).to receive(:update_issue)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "live_declaration_ambiguous")
    expect(client).not_to have_received(:update_issue)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "does not write for competing candidates or conflicting intent" do
    _user, _cycle, run = cycle_run
    client = instance_double(GithubClient)
    allow(client).to receive(:update_issue)
    conflicting = recommendation(run).deep_dup
    conflicting.fetch("candidates").first["missing_or_conflicting_intent"] = [ "Owner direction conflicts." ]

    result = described_class.call(agent_run: run, recommendation: conflicting, client_resolver: ->(_) { client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "not_obvious")
    expect(client).not_to have_received(:update_issue)
  end

  def cycle_run
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, status: "running", goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) })
    [ user, cycle, run ]
  end

  def recommendation(run)
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    removed = snapshot.fetch("effective_edges").first
    {
      "summary" => "The first declaration is obsolete.",
      "candidates" => [ {
        "declaration_changes" => [ { "edge_id" => removed.fetch("id"), "action" => "remove" } ],
        "evidence" => [ "The dependency contradicts the ordered implementation plan." ],
        "tradeoffs" => [ "The source issue may proceed." ],
        "missing_or_conflicting_intent" => [],
        "resulting_graph" => { "issue_ids" => snapshot.fetch("issues").pluck("id"),
          "edges" => snapshot.fetch("effective_edges").drop(1).map { |edge| edge.slice("from_issue_id", "to_issue_id") } },
        "acyclic" => true
      } ]
    }
  end
end
