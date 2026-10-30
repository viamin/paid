# frozen_string_literal: true

require "rails_helper"

RSpec.describe CycleAnalyses::Analyze do
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
      external_metadata: { CycleAnalyses::METADATA_KEY => { "occurrence" => cycle.occurrence, "graph_revision" => cycle.graph_revision } })
    llm = class_double(Llm::Request)
    allow(llm).to receive(:call).and_return(double(content: "reviewable recommendation"))
    stub_comments([])

    result = described_class.call(agent_run: run, llm:)

    expect(llm).to have_received(:call) { |prompt:, **| expect(prompt).to include("effective_edges", "Implementation phase", "unavailable_provenance_edge_ids") }
    expect(result).to include("recommendation" => "reviewable recommendation", "graph_revision" => cycle.graph_revision)
  end

  it "caps untrusted issue and trusted-comment content in the prompt" do
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    limit = Prompts::BuildForIssue::DEFAULT_MAX_COMMENT_LENGTH
    first = create(:issue, project:, github_state: "open", body: "a" * (limit + 1))
    second = create(:issue, project:, github_state: "open", body: "short")
    create_legacy_issue_dependency(issue: first, depends_on_issue: second)
    create_legacy_issue_dependency(issue: second, depends_on_issue: first)
    cycle = Issues::DependencyCycles.call(account: user.account).sole
    run = create(:agent_run, project:, initiating_user: user, goal: AgentRun::CYCLE_ANALYSIS_GOAL,
      external_metadata: { CycleAnalyses::METADATA_KEY => { "occurrence" => cycle.occurrence,
        "graph_revision" => cycle.graph_revision } })
    comment = { user: { login: "viamin" }, body: "b" * (limit + 1), html_url: "https://example.test/comment" }
    stub_comments([ comment ])
    llm = class_double(Llm::Request)
    allow(llm).to receive(:call).and_return(double(content: "recommendation"))

    described_class.call(agent_run: run, llm:)

    expect(llm).to have_received(:call) do |prompt:, **|
      expect(prompt).to include("a" * limit, "b" * limit)
      expect(prompt).not_to include("a" * (limit + 1), "b" * (limit + 1))
    end
  end
end
