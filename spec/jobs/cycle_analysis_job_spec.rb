# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalysisJob do
  # @spec AUTO-PICK-QUEUE-016 AUTO-PICK-QUEUE-022
  it "preserves cancellation while analysis is in progress, and never attempts the GitHub write a repair would make" do
    run = cycle_run
    response = AgentHarness::Response.new(output: recommendation(run).to_json, exit_code: 0,
      duration: 1.0, provider: :codex)
    allow(Llm::Request).to receive(:call) do
      AgentRuns::Cancel.call(agent_run: run)
      response
    end
    stub_comments

    described_class.new.perform(run.id)

    expect(run.reload).to have_attributes(status: "cancelled", verification_result: {})
    expect(a_request(:get, %r{\Ahttps://api\.github\.com/repos/[^/]+/[^/]+/issues/\d+\z})).not_to have_been_made
  end

  # @spec AUTO-PICK-QUEUE-016
  it "performs the analysis in the run project's tenant context" do
    run = cycle_run
    response = AgentHarness::Response.new(output: recommendation(run).to_json, exit_code: 0,
      duration: 1.0, provider: :codex)
    allow(Llm::Request).to receive(:call) do
      expect(Current.account).to eq(run.project.account)
      response
    end
    stub_comments

    described_class.perform_now(run.id)

    expect(run.reload.status).to eq("completed")
  end

  # @spec AUTO-PICK-QUEUE-016
  it "preserves cancellation when in-progress analysis then fails" do
    run = cycle_run
    allow(Llm::Request).to receive(:call) do
      AgentRuns::Cancel.call(agent_run: run)
      raise AgentHarness::CommandExecutionError, "provider failed after cancellation"
    end
    stub_comments

    expect { described_class.new.perform(run.id) }
      .to raise_error(AgentHarness::CommandExecutionError)

    expect(run.reload).to have_attributes(status: "cancelled", error_message: nil)
  end

  # @spec AUTO-PICK-QUEUE-018
  it "sanitizes a provider failure before persisting it" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, status: "queued",
      goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) })
    secret = "ghp_#{"a" * 36}"
    response = AgentHarness::Response.new(output: "", exit_code: 1,
      error: "provider rejected #{secret}", duration: 1.0, provider: :codex)
    allow(Llm::Request).to receive(:call).and_return(response)
    stub_comments

    expect { described_class.new.perform(run.id) }.to raise_error(AgentHarness::CommandExecutionError)

    expect(run.reload.error_message).to include("[REDACTED:github_token]")
    expect(run.error_message).not_to include(secret)
  end

  # @spec AUTO-PICK-QUEUE-021 AUTO-PICK-QUEUE-023
  it "repairs an obvious correction and confirms the graph acyclic" do
    run = cycle_run
    declaring_issue, = provenanced_edge_issues(run)
    run = run.reload
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    edge_id = snapshot.fetch("effective_edges").find { |e| e.fetch("from_issue_id") == declaring_issue.id }.fetch("id")
    response = repair_response(edge_id:, snapshot:)
    allow(Llm::Request).to receive(:call).and_return(response)
    stub_github_for_repair(declaring_issue)

    described_class.perform_now(run.id)

    run.reload
    expect(run.verification_result.dig(CycleAnalyses::RESULT_KEY, "repair", "status")).to eq("repaired")
    expect(Issues::DependencyCycles.call(account: run.project.account)).to be_empty
  end

  # @spec AUTO-PICK-QUEUE-021
  it "does not attempt a repair when the recommendation carries conflicting intent" do
    run = cycle_run
    output = recommendation(run)
    output[:candidates].first[:missing_or_conflicting_intent] = [ "Owner disputes removal" ]
    response = AgentHarness::Response.new(output: output.to_json, exit_code: 0, duration: 1.0, provider: :codex)
    allow(Llm::Request).to receive(:call).and_return(response)
    stub_comments

    described_class.perform_now(run.id)

    repair = run.reload.verification_result.dig(CycleAnalyses::RESULT_KEY, "repair")
    expect(repair).to eq({ "status" => "not_attempted", "reason" => "no_qualifying_candidate" })
    expect(Issues::DependencyCycles.call(account: run.project.account)).not_to be_empty
  end

  def provenanced_edge_issues(run)
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    edge = snapshot.fetch("effective_edges").first
    declaring_issue = Issue.find(edge.fetch("from_issue_id"))
    target_issue = Issue.find(edge.fetch("to_issue_id"))
    declaring_issue.update!(body: "Depends on ##{target_issue.github_number}")
    declaring_issue.issue_dependencies.update_all(declaration_source: "issue_body", declaration_url: "https://example.test/edge")
    new_snapshot = CycleAnalyses::Snapshot.call(cycle: Issues::DependencyCycles.call(account: run.project.account).sole)
    run.update!(external_metadata: { CycleAnalyses::METADATA_KEY => new_snapshot })
    [ declaring_issue, target_issue ]
  end

  def repair_response(edge_id:, snapshot:)
    AgentHarness::Response.new(output: {
      summary: "Obvious fix.",
      candidates: [ {
        declaration_changes: [ { edge_id: edge_id, action: "remove" } ],
        evidence: [ "Clear duplicate declaration." ],
        tradeoffs: [ "None; the declaration was already obsolete." ], missing_or_conflicting_intent: [],
        resulting_graph: {
          issue_ids: snapshot.fetch("issues").pluck("id"),
          edges: snapshot.fetch("effective_edges").reject { |e| e.fetch("id") == edge_id }
            .map { |e| e.slice("from_issue_id", "to_issue_id").symbolize_keys }
        },
        acyclic: true
      } ]
    }.to_json, exit_code: 0, duration: 1.0, provider: :codex)
  end

  def stub_github_for_repair(declaring_issue)
    body = declaring_issue.body
    github_client = instance_double(GithubClient, recent_issue_comments: [], issue_comments: [])
    allow(github_client).to receive(:issue) { Struct.new(:body).new(body) }
    allow(github_client).to receive(:update_issue) { |_repo, _number, **options| body = options.fetch(:body); true }
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  def recommendation(run)
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    remaining_edges = snapshot.fetch("effective_edges").drop(1)
      .map { |edge| edge.slice("from_issue_id", "to_issue_id").symbolize_keys }
    {
      summary: "Review both declarations.",
      candidates: [ {
        declaration_changes: [ { edge_id: snapshot.fetch("effective_edges").first.fetch("id"), action: "remove" } ],
        evidence: [ "The declaration is obsolete." ],
        tradeoffs: [ "Work may become eligible sooner." ],
        missing_or_conflicting_intent: [],
        resulting_graph: { issue_ids: snapshot.fetch("issues").pluck("id"), edges: remaining_edges },
        acyclic: true
      } ]
    }
  end

  def cycle_run
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    first = create(:issue, project:, github_state: "open")
    second = create(:issue, project:, github_state: "open")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    create(:agent_run, project:, initiating_user: user, status: "queued",
      goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => CycleAnalyses::Snapshot.call(cycle:) })
  end

  def stub_comments
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/.*/issues/\d+/comments(?:\?.*)?\z})
      .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })
    stub_request(:get, %r{\Ahttps://api\.github\.com/repos/[^/]+/[^/]+/issues/\d+\z})
      .to_return(status: 200, body: { body: "" }.to_json, headers: { "Content-Type" => "application/json" })
  end
end
