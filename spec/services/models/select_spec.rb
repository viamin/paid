# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::Select do
  describe ".call" do
    let(:project) { create(:project) }
    let(:agent_run) { create(:agent_run, project: project) }

    context "with project model override" do
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
    end

    context "with rules-based fallback" do
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
