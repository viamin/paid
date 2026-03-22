# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::Select do
  describe ".call" do
    let(:project) { create(:project) }
    let(:agent_run) { create(:agent_run, project: project) }

    before do
      # Default: meta-agent returns nil so rules-based fallback is used
      allow(Models::MetaAgentSelector).to receive(:call).and_return(nil)
    end

    context "with project model override (required_model_id)" do
      let!(:llm_model) { create(:llm_model, model_id: "claude-sonnet-4-6") }

      before do
        project.update!(model_preferences: { "required_model_id" => "claude-sonnet-4-6" })
      end

      it "selects the overridden model" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.llm_model).to eq(llm_model)
        expect(selection.selector_type).to eq("override")
      end

      it "persists a ModelSelection record" do
        expect { described_class.call(agent_run: agent_run) }
          .to change(ModelSelection, :count).by(1)
      end

      it "does not call meta-agent or rules-based selector" do
        described_class.call(agent_run: agent_run)

        expect(Models::MetaAgentSelector).not_to have_received(:call)
      end
    end

    context "with project preferred models" do
      let!(:preferred_model) { create(:llm_model, model_id: "gpt-4o", capability_score: 8.5) }

      before do
        create(:llm_model, model_id: "claude-sonnet-4-6", capability_score: 9.0)
        project.update!(model_preferences: { "preferred_model_ids" => [ "gpt-4o" ] })
      end

      it "selects the preferred model" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).to eq(preferred_model)
        expect(selection.selector_type).to eq("override")
        expect(selection.reasoning).to include("preferred")
      end

      it "does not call meta-agent selector" do
        described_class.call(agent_run: agent_run)

        expect(Models::MetaAgentSelector).not_to have_received(:call)
      end
    end

    context "when preferred model is inactive" do
      before do
        create(:llm_model, model_id: "gpt-4o", active: false)
        create(:llm_model, model_id: "claude-sonnet-4-6")
        project.update!(model_preferences: { "preferred_model_ids" => [ "gpt-4o" ] })
      end

      it "falls through to meta-agent/rules selection" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.selector_type).to eq("rules")
      end
    end

    context "with meta-agent selection" do
      let!(:llm_model) { create(:llm_model, model_id: "claude-sonnet-4-6", capability_score: 9.0) }

      before do
        allow(Models::MetaAgentSelector).to receive(:call).and_return({
          model: llm_model,
          selector_type: "meta_agent",
          reasoning: "Complex task needs high capability",
          candidates: [ { model_id: "claude-sonnet-4-6", score: 9.0 } ],
          complexity_score: 7.5
        })
      end

      it "uses meta-agent result" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.selector_type).to eq("meta_agent")
        expect(selection.reasoning).to eq("Complex task needs high capability")
        expect(selection.complexity_score).to eq(7.5)
      end
    end

    context "when meta-agent fails and falls back to rules" do
      before { create(:llm_model) }

      it "selects a model via rules" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.selector_type).to eq("rules")
      end

      it "records selection duration" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.selection_duration_ms).to be_a(Integer)
        expect(selection.selection_duration_ms).to be >= 0
      end
    end

    context "when no models are available" do
      it "returns nil" do
        expect(described_class.call(agent_run: agent_run)).to be_nil
      end
    end

    context "when override model does not exist" do
      before do
        create(:llm_model)
        project.update!(model_preferences: { "required_model_id" => "nonexistent-model" })
      end

      it "falls back to rules-based selection" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.selector_type).to eq("rules")
      end
    end
  end
end
