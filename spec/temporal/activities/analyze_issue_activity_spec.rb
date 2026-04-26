# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::AnalyzeIssueActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) do
    create(:issue, :in_progress,
      project: project,
      github_number: 42,
      title: "Add audit log",
      body: "Record user actions for compliance tracking")
  end
  let(:agent_run) { create(:agent_run, project: project, issue: issue, goal: "analyze_issue") }
  let(:client) { instance_double(GithubClient) }
  let(:gh_issue) do
    OpenStruct.new(
      title: issue.title,
      number: issue.github_number,
      body: issue.body,
      user: OpenStruct.new(login: "viamin")
    )
  end
  let(:comments) do
    [
      OpenStruct.new(
        body: "Please include controller specs",
        user: OpenStruct.new(login: "maintainer"),
        created_at: Time.zone.parse("2026-04-20 12:00:00 UTC")
      )
    ]
  end
  let(:llm_output) do
    {
      sufficient_context: true,
      reasoning: "The issue has a clear description with acceptance criteria and the knowledge base contains relevant architecture context.",
      missing_context_areas: []
    }.to_json
  end
  let(:llm_response) do
    instance_double(
      AgentHarness::Response,
      success?: true,
      output: llm_output,
      tokens: true,
      input_tokens: 100,
      output_tokens: 40,
      model: "claude-sonnet-4-6"
    )
  end

  before do
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive(:issue).with(project.full_name, issue.github_number).and_return(gh_issue)
    allow(client).to receive(:issue_comments).with(project.full_name, issue.github_number).and_return(comments)
    allow(Knowledge::Search).to receive(:call).and_return(
      results: [
        { title: "AuditLog", content: "app/models/audit_log.rb tracks user actions", path: "app/models/audit_log.rb" }
      ],
      meta: { total: 1 }
    )
    allow(Knowledge::ContextBundle::Build).to receive(:call).and_return(
      content: "## Codebase Context\n### Related Code\n- AuditLog",
      sections: [ :symbols ],
      total_tokens: 10
    )
    allow(AgentHarness).to receive(:send_message).and_return(llm_response)
    allow(ProcessRunQueueJob).to receive(:perform_later)
  end

  describe "#execute" do
    it "returns sufficient_context: true for a well-described issue with knowledge context" do
      result = activity.execute(agent_run_id: agent_run.id)

      expect(result).to include(
        agent_run_id: agent_run.id,
        issue_number: issue.github_number,
        sufficient_context: true,
        reasoning: a_string_including("clear description"),
        missing_context_areas: []
      )
      expect(agent_run.reload.status).to eq("completed")
      expect(issue.reload.paid_state).to eq("analyzed")
    end

    it "returns sufficient_context: false for a vague issue with no knowledge match" do
      allow(Knowledge::Search).to receive(:call).and_return(results: [], meta: {})
      allow(Knowledge::ContextBundle::Build).to receive(:call).and_return(
        content: "", sections: [], total_tokens: 0
      )
      allow(llm_response).to receive(:output).and_return(
        {
          sufficient_context: false,
          reasoning: "The issue lacks implementation details and acceptance criteria.",
          missing_context_areas: [ "acceptance criteria", "affected components" ]
        }.to_json
      )

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:sufficient_context]).to be false
      expect(result[:missing_context_areas]).to include("acceptance criteria", "affected components")
      expect(agent_run.reload.status).to eq("completed")
      expect(issue.reload.paid_state).to eq("analyzed")
    end

    it "raises a non-retryable error when the LLM returns malformed JSON" do
      allow(llm_response).to receive(:output).and_return("not json at all")

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError, "LLM returned invalid analysis JSON")
    end

    it "raises a non-retryable error when the LLM response is missing required keys" do
      allow(llm_response).to receive(:output).and_return({ foo: "bar" }.to_json)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError, "LLM returned invalid analysis JSON")
    end

    it "tracks token usage correctly" do
      activity.execute(agent_run_id: agent_run.id)

      expect(agent_run.token_usages.last).to have_attributes(
        request_type: "agent",
        metadata: include("operation" => "analyze_issue")
      )
    end

    it "updates issue paid_state to analyzed" do
      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.paid_state).to eq("analyzed")
    end

    it "queries knowledge search and context bundle" do
      activity.execute(agent_run_id: agent_run.id)

      expect(Knowledge::Search).to have_received(:call).with(hash_including(
        project: project,
        mode: "hybrid",
        limit: described_class::MAX_SEARCH_RESULTS
      ))
      expect(Knowledge::ContextBundle::Build).to have_received(:call).with(
        issue: issue, project: project, agent_run: agent_run
      )
    end

    it "continues with fallback context when the knowledge base is unavailable" do
      allow(Knowledge::Search).to receive(:call).and_raise(StandardError, "index unavailable")
      allow(Knowledge::ContextBundle::Build).to receive(:call).and_raise(StandardError, "bundle unavailable")

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:sufficient_context]).to be true
      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("No retrieval results.", "No context bundle entries were available."),
        hash_including(provider: :claude)
      )
    end

    it "does not post any GitHub comment" do
      activity.execute(agent_run_id: agent_run.id)

      expect(client).not_to have_received(:add_comment) if client.respond_to?(:add_comment)
    end

    it "logs the analysis result to agent_run_logs" do
      activity.execute(agent_run_id: agent_run.id)

      log = agent_run.reload.agent_run_logs.last
      expect(log).to be_present
      expect(log.content).to include("sufficient_context")
    end

    it "raises GitHub API failures before calling the LLM" do
      allow(client).to receive(:issue).and_raise(GithubClient::Error.new("GitHub unavailable"))

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(GithubClient::Error, "GitHub unavailable")

      expect(AgentHarness).not_to have_received(:send_message)
    end

    it "defaults missing_context_areas to an empty array when not in response" do
      allow(llm_response).to receive(:output).and_return(
        { sufficient_context: true, reasoning: "All clear" }.to_json
      )

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:missing_context_areas]).to eq([])
    end
  end
end
