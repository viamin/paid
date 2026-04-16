# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::RulesBasedSelector do
  describe ".call" do
    let(:agent_run) { create(:agent_run) }

    before do
      create(:llm_model, capability_score: 9.0, model_id: "best-model", tier: "high")
      create(:llm_model, capability_score: 5.0, model_id: "basic-model", tier: "low")
    end

    it "returns a result with a selected model" do
      result = described_class.call(agent_run: agent_run)

      expect(result).to be_present
      expect(result[:model]).to be_a(LlmModel)
      expect(result[:selector_type]).to eq("rules")
    end

    it "selects higher capability models for complex tasks" do
      agent_run.issue.update!(body: "A" * 5000)

      result = described_class.call(agent_run: agent_run)

      expect(result[:model].capability_score.to_f).to be >= 8.0
    end

    it "returns nil when no models are available" do
      LlmModel.destroy_all

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end

    describe "tier-based routing" do
      let!(:low_model)  { create(:llm_model, :cheap, model_id: "tier-low", tier: "low",  capability_score: 4.0) }
      let!(:mid_model)  { create(:llm_model,        model_id: "tier-mid", tier: "mid",  capability_score: 7.0) }
      let!(:high_model) { create(:llm_model, :expensive, model_id: "tier-high", tier: "high", capability_score: 9.5) }

      before do
        LlmModel.where.not(id: [ low_model.id, mid_model.id, high_model.id ]).destroy_all
      end

      it "routes simple tasks (low complexity) to the low tier" do
        # create_issue with a short issue body drives the complexity estimator
        # below the low_max threshold when the project overrides it to 3.
        agent_run.project.update!(
          model_preferences: { "complexity_thresholds" => { "low_max" => 4, "mid_max" => 7 } }
        )
        run = create(:agent_run, :create_issue_goal, project: agent_run.project)

        result = described_class.call(agent_run: run)

        expect(result[:tier]).to eq("low")
        expect(result[:model]).to eq(low_model)
      end

      it "routes medium tasks to the mid tier" do
        # Short issue body yields complexity 4.0 which lands in "mid" with the
        # default thresholds (low_max=3, mid_max=7).
        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("mid")
        expect(result[:model]).to eq(mid_model)
      end

      it "routes complex tasks to the high tier" do
        agent_run.issue.update!(body: "A" * 5000)
        agent_run.update!(source_pull_request_number: 99)

        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("high")
        expect(result[:model]).to eq(high_model)
      end

      it "respects project excluded_model_ids even within a tier" do
        agent_run.project.update!(
          model_preferences: { "excluded_model_ids" => [ mid_model.model_id ] }
        )
        # Default complexity is 5.0 => mid tier. Excluding mid_model should
        # yield zero tier candidates, so the fallback pool is used instead.
        result = described_class.call(agent_run: agent_run)

        expect(result[:model]).not_to eq(mid_model)
      end

      it "honors project-level threshold overrides" do
        agent_run.project.update!(
          model_preferences: { "complexity_thresholds" => { "low_max" => 6, "mid_max" => 8 } }
        )
        # Complexity 4.0 (short body) now falls into the "low" tier with
        # low_max=6.
        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("low")
        expect(result[:model]).to eq(low_model)
      end

      it "honors provider-level threshold overrides on the agent run" do
        provider = create(:provider, user: agent_run.project.effective_owner)
        provider.update!(complexity_thresholds: { "low_max" => 3, "mid_max" => 9 })
        agent_run.update!(provider: provider)

        # Complexity 4.0 (short body) → above low_max=3, below mid_max=9 →
        # "mid". With default thresholds (mid_max=7) this would also be "mid",
        # so the next update below proves thresholds are actually used.
        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("mid")

        # Reconfigure so mid_max=3 ⇒ complexity 4.0 routes to high.
        provider.update!(complexity_thresholds: { "low_max" => 2, "mid_max" => 3 })
        agent_run.reload
        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("high")
      end

      it "falls back to the broader pool when the tier has no active models" do
        high_model.update!(active: false)
        agent_run.issue.update!(body: "A" * 5000)
        agent_run.update!(source_pull_request_number: 99)

        result = described_class.call(agent_run: agent_run)

        expect(result).to be_present
        expect(result[:tier]).to eq("high")
        expect(result[:model]).not_to eq(high_model)
      end
    end
  end
end
