# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalysisJob do
  # @spec AUTO-PICK-QUEUE-016
  it "preserves cancellation while analysis is in progress" do
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

  def recommendation(run)
    snapshot = run.external_metadata.fetch(CycleAnalyses::METADATA_KEY)
    {
      summary: "Review both declarations.",
      candidates: [ {
        declaration_changes: [ { edge_id: snapshot.fetch("effective_edges").first.fetch("id"), action: "remove" } ],
        evidence: [ "The declaration is obsolete." ],
        tradeoffs: [ "Work may become eligible sooner." ],
        missing_or_conflicting_intent: [],
        resulting_graph: { issue_ids: snapshot.fetch("issues").pluck("id"), edges: [] },
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
    stub_request(:get, %r{api.github.com/repos/.*/issues/\d+/comments})
      .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })
  end
end
