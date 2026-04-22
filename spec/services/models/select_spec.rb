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
      let!(:llm_model) { create(:llm_model, model_id: "claude-sonnet-4-6", tier: "high") }

      before do
        project.update!(model_preferences: { "required_model_id" => "claude-sonnet-4-6" })
      end

      it "selects the overridden model" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.llm_model).to eq(llm_model)
        expect(selection.selector_type).to eq("override")
      end

      it "records the tier from the selected model" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.tier).to eq("high")
      end

      it "persists a ModelSelection record" do
        expect { described_class.call(agent_run: agent_run) }
          .to change(ModelSelection, :count).by(1)
      end

      it "does not call meta-agent or rules-based selector" do
        allow(Models::RulesBasedSelector).to receive(:call)

        described_class.call(agent_run: agent_run)

        expect(Models::MetaAgentSelector).not_to have_received(:call)
        expect(Models::RulesBasedSelector).not_to have_received(:call)
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

    context "with multiple preferred models respects ordering" do
      let!(:higher_capability) { create(:llm_model, model_id: "claude-sonnet-4-6", capability_score: 9.0) }
      let!(:first_choice) { create(:llm_model, model_id: "gpt-4o", capability_score: 7.0) }

      before do
        project.update!(model_preferences: { "preferred_model_ids" => [ "gpt-4o", "claude-sonnet-4-6" ] })
      end

      it "selects the first active model in preference order, not by capability" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).to eq(first_choice)
        expect(selection.llm_model).not_to eq(higher_capability)
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

    context "with tenant model preference" do
      let!(:tenant_model) { create(:llm_model, model_id: "claude-tenant-default", tier: "high") }

      before do
        create(:tenant_setting, account: project.account,
          provider_preferences: { "model_preferences" => { "claude" => tenant_model.model_id } })
      end

      it "selects the tenant default model for the run provider" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).to eq(tenant_model)
        expect(selection.selector_type).to eq("override")
        expect(selection.reasoning).to include("Tenant preferred model")
      end
    end

    context "with meta-agent selection" do
      let!(:llm_model) { create(:llm_model, model_id: "claude-sonnet-4-6", capability_score: 9.0) }

      before do
        allow(Models::MetaAgentSelector).to receive(:call).and_return({
          model: llm_model,
          selector_type: "meta_agent",
          tier: "high",
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

      it "persists the meta-agent tier" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.tier).to eq("high")
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

    context "when required_model_id bypasses tier logic (regression)" do
      let!(:low_tier_model) { create(:llm_model, model_id: "cheap-model", tier: "low", capability_score: 3.0) }

      before do
        # Even with max_tier set, required_model_id must always win
        project.update!(model_preferences: {
          "required_model_id" => "cheap-model",
          "max_tier" => "high"
        })
      end

      it "selects the required model regardless of tier settings" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection.llm_model).to eq(low_tier_model)
        expect(selection.selector_type).to eq("override")
        expect(selection.tier).to eq("low")
      end

      it "does not invoke tier-based selectors" do
        allow(Models::RulesBasedSelector).to receive(:call)

        described_class.call(agent_run: agent_run)

        expect(Models::MetaAgentSelector).not_to have_received(:call)
        expect(Models::RulesBasedSelector).not_to have_received(:call)
      end
    end

    context "with max_tier project preference" do
      before do
        create(:llm_model, model_id: "powerful-model", tier: "high", capability_score: 9.5)
        create(:llm_model, model_id: "mid-model", tier: "mid", capability_score: 7.0)
        project.update!(model_preferences: { "max_tier" => "mid" })
      end

      it "caps tier selection to the max_tier" do
        selection = described_class.call(agent_run: agent_run)

        expect(selection).to be_a(ModelSelection)
        expect(selection.tier).to be_in(%w[low mid])
      end
    end
  end
end
