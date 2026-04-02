# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::DecomposeFeatureActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project, title: "Add OAuth", body: "Implement OAuth 2.0 login") }

  describe "#execute" do
    let(:llm_response) do
      instance_double(
        AgentHarness::Response,
        success?: true,
        output: llm_output,
        error: nil
      )
    end

    let(:llm_output) do
      <<~JSON
        [
          {"title": "Add OAuth migration", "description": "Create oauth_tokens table", "dependencies": [], "parallel_group": 0},
          {"title": "Implement OAuth model", "description": "Create OAuthToken model", "dependencies": [0], "parallel_group": 1},
          {"title": "Add OAuth controller", "description": "Create OAuth callback endpoint", "dependencies": [1], "parallel_group": 2}
        ]
      JSON
    end

    let(:knowledge_context) do
      { issue_title: "Add OAuth", knowledge_snippets: [] }
    end

    before do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response)
    end

    it "returns parsed tasks from LLM output" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        knowledge_context: knowledge_context
      )

      tasks = result[:tasks]
      expect(tasks.size).to eq(3)
      expect(tasks[0][:title]).to eq("Add OAuth migration")
      expect(tasks[0][:dependencies]).to eq([])
      expect(tasks[0][:parallel_group]).to eq(0)
      expect(tasks[1][:dependencies]).to eq([ 0 ])
      expect(tasks[2][:dependencies]).to eq([ 1 ])
    end

    it "calls AgentHarness with the correct provider and model" do
      activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        knowledge_context: knowledge_context
      )

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("Add OAuth"),
        provider: :claude,
        model: described_class::DEFAULT_MODEL,
        timeout: described_class::TIMEOUT
      )
    end

    it "includes knowledge context in the prompt when available" do
      context_with_knowledge = knowledge_context.merge(
        knowledge_snippets: [ { title: "Auth docs", content: "OAuth pattern info" } ]
      )

      activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        knowledge_context: context_with_knowledge
      )

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("Auth docs"),
        anything
      )
    end

    context "when LLM returns a single task" do
      let(:llm_output) do
        '[{"title": "Simple fix", "description": "Just update the config", "dependencies": [], "parallel_group": 0}]'
      end

      it "returns a single task" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          knowledge_context: knowledge_context
        )

        expect(result[:tasks].size).to eq(1)
        expect(result[:tasks][0][:title]).to eq("Simple fix")
      end
    end

    context "when LLM returns markdown-fenced JSON" do
      let(:llm_output) do
        <<~OUTPUT
          ```json
          [{"title": "Task 1", "description": "Do thing", "dependencies": [], "parallel_group": 0}]
          ```
        OUTPUT
      end

      it "strips the markdown fence and parses correctly" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          knowledge_context: knowledge_context
        )

        expect(result[:tasks].size).to eq(1)
        expect(result[:tasks][0][:title]).to eq("Task 1")
      end
    end

    context "when LLM call fails" do
      let(:llm_response) do
        instance_double(AgentHarness::Response, success?: false, output: nil, error: "Rate limited")
      end

      it "raises an ApplicationError" do
        expect {
          activity.execute(
            project_id: project.id,
            issue_id: issue.id,
            knowledge_context: knowledge_context
          )
        }.to raise_error(Temporalio::Error::ApplicationError, /LLM decomposition failed/)
      end
    end

    context "when LLM returns invalid JSON" do
      let(:llm_output) { "This is not valid JSON at all" }

      it "raises an ApplicationError" do
        expect {
          activity.execute(
            project_id: project.id,
            issue_id: issue.id,
            knowledge_context: knowledge_context
          )
        }.to raise_error(Temporalio::Error::ApplicationError, /Failed to parse/)
      end
    end

    context "when LLM returns non-array JSON" do
      let(:llm_output) { '{"title": "Not an array"}' }

      it "raises an ApplicationError" do
        expect {
          activity.execute(
            project_id: project.id,
            issue_id: issue.id,
            knowledge_context: knowledge_context
          )
        }.to raise_error(Temporalio::Error::ApplicationError, /non-array/)
      end
    end

    it "truncates tasks to MAX_TASKS" do
      many_tasks = (0..25).map do |i|
        { title: "Task #{i}", description: "Desc #{i}", dependencies: [], parallel_group: i }
      end
      allow(llm_response).to receive(:output).and_return(many_tasks.to_json)

      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        knowledge_context: knowledge_context
      )

      expect(result[:tasks].size).to eq(described_class::MAX_TASKS)
    end
  end
end
