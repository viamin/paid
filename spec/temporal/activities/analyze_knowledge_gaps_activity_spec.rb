# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::AnalyzeKnowledgeGapsActivity do
  let(:activity) { described_class.new }

  describe "class" do
    it "inherits from BaseActivity" do
      expect(described_class.superclass).to eq(Activities::BaseActivity)
    end
  end

  describe "#execute" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    let(:sampled_runs) do
      [
        {
          agent_run_id: 1,
          issue_title: "Add user auth",
          questions_asked: [ "How does the auth flow work?" ],
          knowledge_available: { "route" => 15 },
          sufficient_context: false
        }
      ]
    end

    let(:artifact_usage) do
      { "route" => { total_runs: 50, success_rate: 80.0 } }
    end

    let(:input) do
      { project_id: project.id, sampled_runs: sampled_runs, artifact_usage: artifact_usage }
    end

    let(:llm_output) do
      {
        recommendations: [
          {
            recommendation_type: "add_collector",
            collector_type: "database_schema",
            priority: "high",
            description: "Collects database schemas to answer data model questions",
            evidence: { gap_frequency: 5, example_questions: [ "How does User relate to Account?" ] }
          }
        ]
      }.to_json
    end

    let(:llm_response) { instance_double(AgentHarness::Response, output: llm_output) }

    before do
      allow(AgentHarness).to receive(:send_message).and_return(llm_response)
      allow(Llm::TextMode).to receive(:options).and_return({})
    end

    it "calls AgentHarness with a prompt" do
      activity.execute(input)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("knowledge base effectiveness"),
        hash_including(provider: :claude, model: "claude-sonnet-4-6")
      )
    end

    it "returns parsed recommendations" do
      result = activity.execute(input)

      expect(result[:project_id]).to eq(project.id)
      expect(result[:recommendations].size).to eq(1)
      expect(result[:recommendations].first[:recommendation_type]).to eq("add_collector")
      expect(result[:recommendations].first[:collector_type]).to eq("database_schema")
    end

    context "when LLM returns invalid JSON" do
      let(:llm_output) { "This is not valid JSON" }

      it "returns empty recommendations" do
        result = activity.execute(input)

        expect(result[:recommendations]).to be_empty
      end
    end

    context "when AgentHarness raises an error" do
      before do
        allow(AgentHarness).to receive(:send_message).and_raise(AgentHarness::Error, "timeout")
      end

      it "returns empty recommendations" do
        result = activity.execute(input)

        expect(result[:recommendations]).to be_empty
      end
    end

    context "when LLM returns empty recommendations" do
      let(:llm_output) { { recommendations: [] }.to_json }

      it "returns empty recommendations" do
        result = activity.execute(input)

        expect(result[:recommendations]).to be_empty
      end
    end
  end
end
