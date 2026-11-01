# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe CycleAnalyses::Repair do
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user) }
  let(:client) { instance_double(GithubClient) }
  let(:first) { create(:issue, project:, github_state: "open", body: "## Dependencies\n- #2\n- #3") }
  let(:second) { create(:issue, project:, github_number: 2, github_state: "open") }
  let(:third) { create(:issue, project:, github_number: 3, github_state: "open") }
  let(:run) { cycle_run(first:, second:) }

  before do
    allow(Issue).to receive(:find).and_wrap_original do |find, *args|
      find.call(*args).tap { |record| allow(record.project).to receive(:client).and_return(client) }
    end
    allow(client).to receive_messages(authenticated_login: "viamin", recent_issue_comments: [], issue: OpenStruct.new(body: first.body))
  end

  # @spec AUTO-PICK-QUEUE-021 AUTO-PICK-QUEUE-022
  it "removes the uniquely selected live declaration through the trusted client" do
    edge = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY).fetch("effective_edges")
      .find { |item| item.fetch("from_issue_id") == first.id }
    recommendation = recommendation_for(run, edge_id: edge.fetch("id"))
    allow(client).to receive(:issue).and_return(OpenStruct.new(body: first.body))
    expect(client).to receive(:update_issue).with(project.full_name, first.github_number,
      body: "## Dependencies\n- #3")

    result = described_class.call(agent_run: run, candidate: recommendation, actor: user)

    expect(result).to have_attributes(status: :applied), result.message
  end

  # @spec AUTO-PICK-QUEUE-021
  it "excludes untrusted comments from the immediate dependency reparse" do
    untrusted_target = create(:issue, project:, github_number: 4, github_state: "open")
    untrusted_comment = OpenStruct.new(
      body: "Depends on #4", html_url: "https://github.com/example/repo/issues/1#issuecomment-1",
      user: OpenStruct.new(login: "attacker")
    )
    allow(client).to receive(:recent_issue_comments).and_return([ untrusted_comment ])
    allow(client).to receive(:update_issue)
    edge = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY).fetch("effective_edges")
      .find { |item| item.fetch("from_issue_id") == first.id }

    result = described_class.call(agent_run: run, candidate: recommendation_for(run, edge_id: edge.fetch("id")), actor: user)

    expect(result).to have_attributes(status: :applied), result.message
    expect(first.reload.issue_dependencies.where(depends_on_issue: untrusted_target)).not_to exist
  end

  # @spec AUTO-PICK-QUEUE-021 AUTO-PICK-QUEUE-022
  it "removes a uniquely selected declaration from an admitted trusted comment" do
    comment_url = "https://github.com/example/repo/issues/1#issuecomment-1"
    run
    first.update!(body: "## Dependencies\n- #3")
    dependency = first.issue_dependencies.find_by!(depends_on_issue: second)
    dependency.update_columns(declaration_source: "issue_comment", declaration_url: comment_url)
    allow(client).to receive(:issue).and_return(OpenStruct.new(body: first.body))
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run.update!(external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) })
    edge = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY).fetch("effective_edges")
      .find { |item| item.fetch("from_issue_id") == first.id }
    comment = OpenStruct.new(id: 1, body: "Depends on #2", html_url: comment_url, user: OpenStruct.new(login: "viamin"))
    updated_comment = OpenStruct.new(id: 1, body: "Depends on", html_url: comment_url, user: OpenStruct.new(login: "viamin"))
    allow(client).to receive(:recent_issue_comments).and_return([ comment ], [ comment ], [ updated_comment ])
    expect(client).to receive(:update_comment).with(project.full_name, 1, "Depends on")

    result = described_class.call(agent_run: run, candidate: recommendation_for(run, edge_id: edge.fetch("id")), actor: user)

    expect(result).to have_attributes(status: :applied), result.message
    expect(first.reload.issue_dependencies.where(depends_on_issue: second)).not_to exist
  end

  # @spec AUTO-PICK-QUEUE-021
  it "requires mutation authority for every declaration-owning project" do
    allow(ProjectPolicy).to receive(:new).and_return(instance_double(ProjectPolicy, manage_issues?: false))
    result = described_class.call(agent_run: run, candidate: recommendation_for(run), actor: user)

    expect(result.status).to eq(:unauthorized)
  end

  # @spec AUTO-PICK-QUEUE-021
  it "requires a trusted human credential before reading or writing the declaration" do
    allow(client).to receive(:authenticated_login).and_return("paid-agents[bot]")

    expect(client).not_to receive(:issue)
    expect(client).not_to receive(:update_issue)
    result = described_class.call(agent_run: run, candidate: recommendation_for(run), actor: user)

    expect(result.status).to eq(:needs_operator_action)
  end

  # @spec AUTO-PICK-QUEUE-021
  it "does not write when the persisted cycle is stale" do
    run.external_metadata[CycleAnalyses::METADATA_KEY]["occurrence"] = "state:old"
    run.save!

    expect(client).not_to receive(:update_issue)
    result = described_class.call(agent_run: run, candidate: recommendation_for(run), actor: user)

    expect(result.status).to eq(:stale)
  end

  # @spec AUTO-PICK-QUEUE-021 AUTO-PICK-QUEUE-022
  it "rejects multiple selected declarations before the first write" do
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    first_edge = snapshot.fetch("effective_edges").find { |edge| edge.fetch("from_issue_id") == first.id }
    second_edge = snapshot.fetch("effective_edges").find { |edge| edge.fetch("from_issue_id") == second.id }
    recommendation = recommendation_for(run, edge_ids: [ first_edge.fetch("id"), second_edge.fetch("id") ])
    allow(client).to receive(:issue) do |_repo, number|
      OpenStruct.new(body: number == first.github_number ? first.body : second.body)
    end

    expect(client).not_to receive(:update_issue)
    result = described_class.call(agent_run: run, candidate: recommendation, actor: user)

    expect(result.status).to eq(:needs_operator_action)
    expect(first.reload.body).to eq("## Dependencies\n- #2\n- #3")
  end

  # @spec AUTO-PICK-QUEUE-022
  it "preserves a changed live body and stops when the declaration is no longer unique" do
    edge = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY).fetch("effective_edges")
      .find { |item| item.fetch("from_issue_id") == first.id }
    recommendation = recommendation_for(run, edge_id: edge.fetch("id"))
    changed_body = "Human edit\n\n## Dependencies\n- #2\n- #2\n- #3"
    allow(client).to receive(:issue).and_return(OpenStruct.new(body: first.body), OpenStruct.new(body: changed_body))

    expect(client).not_to receive(:update_issue)
    result = described_class.call(agent_run: run, candidate: recommendation, actor: user)

    expect(result.status).to eq(:needs_operator_action)
  end

  # @spec AUTO-PICK-QUEUE-022
  it "recomputes against a changed live body without clobbering unrelated edits" do
    edge = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY).fetch("effective_edges")
      .find { |item| item.fetch("from_issue_id") == first.id }
    recommendation = recommendation_for(run, edge_id: edge.fetch("id"))
    changed_body = "Human edit\n\n## Dependencies\n- #2\n- #3"
    allow(client).to receive(:issue).and_return(OpenStruct.new(body: first.body), OpenStruct.new(body: changed_body))

    expect(client).to receive(:update_issue).with(project.full_name, first.github_number,
      body: "Human edit\n\n## Dependencies\n- #3")
    result = described_class.call(agent_run: run, candidate: recommendation, actor: user)

    expect(result.status).to eq(:applied)
  end

  # @spec AUTO-PICK-QUEUE-021
  it "removes a cross-project declaration while retaining a same-number local dependency" do
    remote_project = create(:project, account: user.account, created_by: user, owner: "other", repo: "repo")
    local_target = create(:issue, project:, github_number: 42, github_state: "open")
    remote_target = create(:issue, project: remote_project, github_number: 42, github_state: "open")
    first.update!(body: "## Dependencies\n- #42\n- other/repo#42")
    create_legacy_issue_dependency(issue: first, depends_on_issue: remote_target,
      declaration_source: "issue_body", declaration_url: first.github_url)
    create_legacy_issue_dependency(issue: remote_target, depends_on_issue: first,
      declaration_source: "issue_body", declaration_url: remote_target.github_url)
    cycle = Issues::DependencyCycles.call(account: user.account).find { |item| item.issues.map(&:id).sort == [ first.id, remote_target.id ].sort }
    cross_project_run = create(:agent_run, :completed, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) })
    edge = cross_project_run.external_metadata.fetch(CycleAnalyses::METADATA_KEY).fetch("effective_edges")
      .find { |item| item.fetch("from_issue_id") == first.id }
    recommendation = recommendation_for(cross_project_run, edge_id: edge.fetch("id"))

    allow(client).to receive(:issue).and_return(OpenStruct.new(body: first.body))
    expect(client).to receive(:update_issue).with(project.full_name, first.github_number, body: "## Dependencies\n- #42\n")

    result = described_class.call(agent_run: cross_project_run, candidate: recommendation, actor: user)

    expect(result).to have_attributes(status: :applied), result.message
    expect(local_target).to be_present
  end

  def cycle_run(first:, second:)
    create_legacy_issue_dependency(issue: first, depends_on_issue: second,
      declaration_source: "issue_body", declaration_url: first.github_url)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first,
      declaration_source: "issue_body", declaration_url: second.github_url)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    create(:agent_run, :completed, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) })
  end

  def recommendation_for(agent_run, edge_id: nil, edge_ids: nil)
    snapshot = agent_run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    selected_ids = edge_ids || [ edge_id || snapshot.fetch("effective_edges").first.fetch("id") ]
    edges = snapshot.fetch("effective_edges").reject { |edge| selected_ids.include?(edge.fetch("id")) }
      .map { |edge| edge.slice("from_issue_id", "to_issue_id") }
    { "declaration_changes" => selected_ids.map { |id| { "edge_id" => id, "action" => "remove" } },
      "resulting_graph" => { "issue_ids" => snapshot.fetch("issues").pluck("id"), "edges" => edges },
      "acyclic" => true }
  end
end
