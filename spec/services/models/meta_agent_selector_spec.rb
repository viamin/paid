# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::MetaAgentSelector do
  describe ".call" do
    let(:agent_run) { create(:agent_run) }
    let!(:capable_model) { create(:llm_model, model_id: "claude-sonnet-4-6", capability_score: 9.0) }
    let!(:cheap_model) { create(:llm_model, :cheap, model_id: "claude-haiku-4-5-20251001") }

    let(:successful_response) do
      instance_double(
        AgentHarness::Response,
        success?: true,
        output: '{"model": "claude-sonnet-4-6", "reasoning": "Complex task needs high capability", "complexity_score": 7.5}'
      )
    end

    before do
      allow(AgentHarness).to receive(:send_message).and_return(successful_response)
    end

    it "selects a model via LLM meta-agent" do
      result = described_class.call(agent_run: agent_run)

      expect(result).to be_present
      expect(result[:model]).to eq(capable_model)
      expect(result[:selector_type]).to eq("meta_agent")
      expect(result[:reasoning]).to eq("Complex task needs high capability")
      expect(result[:complexity_score]).to eq(7.5)
    end

    it "includes all candidates in the result" do
      result = described_class.call(agent_run: agent_run)

      expect(result[:candidates]).to contain_exactly(
        { model_id: "claude-sonnet-4-6", score: 9.0 },
        { model_id: "claude-haiku-4-5-20251001", score: 5.0 }
      )
    end

    it "sends a prompt to AgentHarness with the correct parameters" do
      described_class.call(agent_run: agent_run)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_matching(/Select the best LLM model/),
        provider: :claude,
        model: "claude-haiku-4-5-20251001",
        timeout: 15
      )
    end

    context "when meta-agent selects a cheap model for simple task" do
      let(:successful_response) do
        instance_double(
          AgentHarness::Response,
          success?: true,
          output: '{"model": "claude-haiku-4-5-20251001", "reasoning": "Simple task, cheap model sufficient", "complexity_score": 2.0}'
        )
      end

      it "selects the cheap model" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:model]).to eq(cheap_model)
        expect(result[:complexity_score]).to eq(2.0)
      end
    end

    context "when AgentHarness returns a failed response" do
      let(:successful_response) do
        instance_double(AgentHarness::Response, success?: false)
      end

      it "returns nil" do
        expect(described_class.call(agent_run: agent_run)).to be_nil
      end
    end

    context "when AgentHarness raises an error" do
      before do
        allow(AgentHarness).to receive(:send_message).and_raise(AgentHarness::Error, "API error")
      end

      it "returns nil" do
        expect(described_class.call(agent_run: agent_run)).to be_nil
      end
    end

    context "when the response selects an unavailable model" do
      let(:successful_response) do
        instance_double(
          AgentHarness::Response,
          success?: true,
          output: '{"model": "nonexistent-model", "reasoning": "bad pick"}'
        )
      end

      it "returns nil" do
        expect(described_class.call(agent_run: agent_run)).to be_nil
      end
    end

    context "when the response is malformed JSON" do
      let(:successful_response) do
        instance_double(
          AgentHarness::Response,
          success?: true,
          output: "not json at all"
        )
      end

      it "returns nil" do
        expect(described_class.call(agent_run: agent_run)).to be_nil
      end
    end

    context "when no models are available" do
      before { LlmModel.destroy_all }

      it "returns nil without calling AgentHarness" do
        result = described_class.call(agent_run: agent_run)

        expect(result).to be_nil
        expect(AgentHarness).not_to have_received(:send_message)
      end
    end

    context "when project has excluded models" do
      before do
        agent_run.project.update!(model_preferences: { "excluded_model_ids" => [ "claude-haiku-4-5-20251001" ] })
      end

      it "excludes those models from candidates" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:candidates]).to eq([ { model_id: "claude-sonnet-4-6", score: 9.0 } ])
      end
    end

    context "when complexity_score is out of range" do
      let(:successful_response) do
        instance_double(
          AgentHarness::Response,
          success?: true,
          output: '{"model": "claude-sonnet-4-6", "reasoning": "test", "complexity_score": 15.0}'
        )
      end

      it "clamps the complexity score to valid range" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:complexity_score]).to eq(10.0)
      end
    end

    context "when response contains JSON wrapped in markdown" do
      let(:successful_response) do
        instance_double(
          AgentHarness::Response,
          success?: true,
          output: "Here is my selection:\n```json\n{\"model\": \"claude-sonnet-4-6\", \"reasoning\": \"best fit\"}\n```"
        )
      end

      it "extracts the JSON and selects the model" do
        result = described_class.call(agent_run: agent_run)

        expect(result[:model]).to eq(capable_model)
      end
    end
  end
end
