# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::Repair do
  # @spec AUTO-PICK-QUEUE-019
  it "removes one uniquely matched section-list declaration when legacy provenance is absent" do
    _user, cycle, run = cycle_run
    edge = cycle.effective_edges.first
    source = Issue.find(edge.from_id)
    target = Issue.find(edge.to_id)
    client = instance_double(GithubClient)
    live = { body: "## Dependencies\n- ##{target.github_number}\n\nKeep this text." }
    allow(client).to receive_messages(issue: live, issue_comments: [])
    allow(client).to receive(:update_issue)
    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "pending_sync", "changed_edge_ids" => [ edge.id ])
    expect(client).to have_received(:update_issue).with(source.project.full_name, source.github_number,
      body: "## Dependencies\n\nKeep this text.")
  end

  # @spec AUTO-PICK-QUEUE-019
  it "removes a uniquely matched declaration from its trusted source comment" do
    _user, cycle, run = cycle_run
    edge = cycle.effective_edges.first
    source = Issue.find(edge.from_id)
    target = Issue.find(edge.to_id)
    comment_url = "https://github.com/#{source.project.full_name}/issues/#{source.github_number}#issuecomment-42"
    IssueDependency.find(edge.id).update_columns(declaration_source: "issue_comment", declaration_url: comment_url)
    comment = Struct.new(:id, :body, :html_url, :user, keyword_init: true).new(
      id: 42, body: "Depends on ##{target.github_number}\n", html_url: comment_url,
      user: GithubClient::CommentAuthor.new(login: "viamin")
    )
    client = instance_double(GithubClient)
    allow(client).to receive(:issue_comments).and_return([ comment ])
    allow(client).to receive(:update_comment)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "pending_sync", "changed_edge_ids" => [ edge.id ])
    expect(client).to have_received(:update_comment).with(source.project.full_name, 42, "")
  end

  # @spec AUTO-PICK-QUEUE-019
  it "requires operator action when quiet mode suppresses the comment write" do
    _user, cycle, run = cycle_run
    edge = cycle.effective_edges.first
    source = Issue.find(edge.from_id)
    source.project.update!(quiet_mode: true)
    target = Issue.find(edge.to_id)
    comment_url = "https://github.com/#{source.project.full_name}/issues/#{source.github_number}#issuecomment-42"
    IssueDependency.find(edge.id).update_columns(declaration_source: "issue_comment", declaration_url: comment_url)
    comment = Struct.new(:id, :body, :html_url, :user, keyword_init: true).new(
      id: 42, body: "Depends on ##{target.github_number}\n", html_url: comment_url,
      user: GithubClient::CommentAuthor.new(login: "viamin")
    )
    client = instance_double(GithubClient, issue_comments: [ comment ])
    allow(client).to receive(:update_comment)
    quiet_client = GithubClient::CommentSuppressing.new(client)

    result = described_class.call(agent_run: run, recommendation: recommendation(run),
      client_resolver: ->(_) { quiet_client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "github_comment_write_suppressed",
      "changed_edge_ids" => [])
    expect(client).not_to have_received(:update_comment)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "removes a uniquely matched cross-project declaration from the issue body" do
    _user, cycle, run = cycle_run
    edge = cycle.effective_edges.first
    source = Issue.find(edge.from_id)
    target = Issue.find(edge.to_id)
    client = instance_double(GithubClient)
    live = { body: "Depends on #{target.project.full_name}##{target.github_number}\n" }
    allow(client).to receive_messages(issue: live, issue_comments: [])
    allow(client).to receive(:update_issue)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "pending_sync", "changed_edge_ids" => [ edge.id ])
    expect(client).to have_received(:update_issue).with(source.project.full_name, source.github_number, body: "")
  end

  # @spec AUTO-PICK-QUEUE-019
  it "does not treat an excluded-section phrase as the live declaration" do
    _user, cycle, run = cycle_run
    edge = cycle.effective_edges.first
    source = Issue.find(edge.from_id)
    target = Issue.find(edge.to_id)
    client = instance_double(GithubClient)
    live = { body: "## Child Issues\n- #999 — Depends on ##{target.github_number} sequencing note\n\n## Dependencies\n- ##{target.github_number}\n" }
    allow(client).to receive_messages(issue: live, issue_comments: [])
    allow(client).to receive(:update_issue)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "pending_sync")
    expect(client).to have_received(:update_issue).with(source.project.full_name, source.github_number,
      body: "## Child Issues\n- #999 — Depends on ##{target.github_number} sequencing note\n\n## Dependencies\n")
  end

  # @spec AUTO-PICK-QUEUE-019
  it "does not write when the live declaration is ambiguous or changed" do
    _user, cycle, run = cycle_run
    target = Issue.find(cycle.effective_edges.first.to_id)
    client = instance_double(GithubClient, issue: { body: "Depends on ##{target.github_number}\nDepends on ##{target.github_number}" })
    allow(client).to receive(:update_issue)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "live_declaration_ambiguous")
    expect(client).not_to have_received(:update_issue)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "does not write when unprovenanced matching declarations occur in the body and a trusted comment" do
    _user, cycle, run = cycle_run
    source = Issue.find(cycle.effective_edges.first.from_id)
    target = Issue.find(cycle.effective_edges.first.to_id)
    comment = Struct.new(:id, :body, :html_url, :user, keyword_init: true).new(
      id: 42, body: "Depends on ##{target.github_number}\n",
      html_url: "https://github.com/#{source.project.full_name}/issues/#{source.github_number}#issuecomment-42",
      user: GithubClient::CommentAuthor.new(login: "viamin")
    )
    client = instance_double(GithubClient, issue: { body: "Depends on ##{target.github_number}\n" }, issue_comments: [ comment ])
    allow(client).to receive(:update_issue)
    allow(client).to receive(:update_comment)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "live_declaration_ambiguous")
    expect(client).not_to have_received(:update_issue)
    expect(client).not_to have_received(:update_comment)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "does not write when one carrier line declares the target twice" do
    _user, cycle, run = cycle_run
    target = Issue.find(cycle.effective_edges.first.to_id)
    client = instance_double(GithubClient, issue: { body: "Depends on ##{target.github_number}, ##{target.github_number}\n" })
    allow(client).to receive(:update_issue)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "live_declaration_ambiguous")
    expect(client).not_to have_received(:update_issue)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "preserves prose around an inline declaration by leaving it for an operator" do
    _user, cycle, run = cycle_run
    target = Issue.find(cycle.effective_edges.first.to_id)
    body = "Depends on ##{target.github_number} because its API must land first\n"
    client = instance_double(GithubClient, issue: { body: body }, issue_comments: [])
    allow(client).to receive(:update_issue)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "live_declaration_not_removable")
    expect(client).not_to have_received(:update_issue)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "does not edit a comment when an unprovenanced body declaration cannot be removed safely" do
    _user, cycle, run = cycle_run
    source = Issue.find(cycle.effective_edges.first.from_id)
    target = Issue.find(cycle.effective_edges.first.to_id)
    comment = Struct.new(:id, :body, :html_url, :user, keyword_init: true).new(
      id: 42, body: "Depends on ##{target.github_number}\n",
      html_url: "https://github.com/#{source.project.full_name}/issues/#{source.github_number}#issuecomment-42",
      user: GithubClient::CommentAuthor.new(login: "viamin")
    )
    client = instance_double(GithubClient,
      issue: { body: "Depends on ##{target.github_number} because its API must land first\n" }, issue_comments: [ comment ])
    allow(client).to receive(:update_comment)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "live_declaration_not_removable")
    expect(client).not_to have_received(:update_comment)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "reports a missing live declaration distinctly from an ambiguous one" do
    _user, _cycle, run = cycle_run
    client = instance_double(GithubClient, issue: { body: "## Dependencies\n- #999" })
    allow(client).to receive(:issue_comments).and_return([])
    allow(client).to receive(:update_issue)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "live_declaration_missing")
    expect(client).not_to have_received(:update_issue)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "recomputes the removal when the body changes between the read and the write" do
    _user, cycle, run = cycle_run
    edge = cycle.effective_edges.first
    source = Issue.find(edge.from_id)
    target = Issue.find(edge.to_id)
    client = instance_double(GithubClient)
    allow(client).to receive(:issue).and_return(
      { body: "## Dependencies\n- ##{target.github_number}\n" },
      { body: "Human note.\n\n## Dependencies\n- ##{target.github_number}\n" }
    )
    allow(client).to receive(:issue_comments).and_return([])
    allow(client).to receive(:update_issue)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "pending_sync", "changed_edge_ids" => [ edge.id ])
    expect(client).to have_received(:update_issue).with(source.project.full_name, source.github_number,
      body: "Human note.\n\n## Dependencies\n")
  end

  # @spec AUTO-PICK-QUEUE-019
  it "does not write when a changed second read no longer carries the declaration" do
    _user, cycle, run = cycle_run
    target = Issue.find(cycle.effective_edges.first.to_id)
    client = instance_double(GithubClient)
    allow(client).to receive(:issue).and_return(
      { body: "## Dependencies\n- ##{target.github_number}\n" },
      { body: "Human edit removed the declaration.\n" }
    )
    allow(client).to receive(:issue_comments).and_return([])
    allow(client).to receive(:update_issue)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "live_declaration_missing")
    expect(client).not_to have_received(:update_issue)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "does not write when a changed second read makes the declaration ambiguous" do
    _user, cycle, run = cycle_run
    target = Issue.find(cycle.effective_edges.first.to_id)
    client = instance_double(GithubClient)
    allow(client).to receive(:issue).and_return(
      { body: "## Dependencies\n- ##{target.github_number}\n" },
      { body: "Depends on ##{target.github_number}\nDepends on ##{target.github_number}\n" }
    )
    allow(client).to receive(:issue_comments).and_return([])
    allow(client).to receive(:update_issue)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "live_declaration_ambiguous")
    expect(client).not_to have_received(:update_issue)
  end

  # @spec AUTO-PICK-QUEUE-019
  it "does not write when the expected resulting edges differ from the live cycle" do
    _user, _cycle, run = cycle_run
    client = instance_double(GithubClient)
    allow(client).to receive(:update_issue)
    mismatched = recommendation(run).deep_dup
    mismatched.fetch("candidates").first.fetch("resulting_graph")["edges"] = []

    result = described_class.call(agent_run: run, recommendation: mismatched, client_resolver: ->(_) { client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "resulting_graph_changed")
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

  # @spec AUTO-PICK-QUEUE-019
  it "does not write when a snapshotted project is no longer available for authorization" do
    _user, _cycle, run = cycle_run
    metadata = run.external_metadata.deep_dup
    metadata.fetch(CycleAnalyses::METADATA_KEY).fetch("project_ids") << -1
    run.update!(external_metadata: metadata)
    client = instance_double(GithubClient)
    allow(client).to receive(:update_issue)

    result = described_class.call(agent_run: run, recommendation: recommendation(run), client_resolver: ->(_) { client })

    expect(result).to include("status" => "needs_operator_action", "reason" => "unauthorized")
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
