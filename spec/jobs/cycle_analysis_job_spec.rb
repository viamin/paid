# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalysisJob do
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
    stub_request(:get, %r{api.github.com/repos/.*/issues/\d+/comments})
      .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

    expect { described_class.new.perform(run.id) }.to raise_error(AgentHarness::CommandExecutionError)

    expect(run.reload.error_message).to include("[REDACTED:github_token]")
    expect(run.error_message).not_to include(secret)
  end
end
