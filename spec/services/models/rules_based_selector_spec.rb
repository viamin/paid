# frozen_string_literal: true

require "rails_helper"

# @spec MODEL-SELECTION-003
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
      agent_run.update!(source_pull_request_number: 99)

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

      it "routes simple tasks to the low tier by default" do
        # Short issue body yields complexity 3.0 which lands in "low" with the
        # default thresholds (low_max=3, mid_max=7), ensuring we default to
        # the cheapest appropriate model.
        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("low")
        expect(result[:model]).to eq(low_model)
      end

      it "routes medium tasks to the mid tier" do
        # body > 1000 bumps complexity to 5.0 which lands in "mid"
        agent_run.issue.update!(body: "A" * 1500)

        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("mid")
        expect(result[:model]).to eq(mid_model)
      end

      it "routes complex tasks to the high tier" do
        # body > 3000 + existing_pr → complexity 3+1+1+2+1 = 8.0 > mid_max(7)
        agent_run.issue.update!(body: "A" * 5000)
        agent_run.update!(source_pull_request_number: 99)

        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("high")
        expect(result[:model]).to eq(high_model)
      end

      it "respects project excluded_model_ids even within a tier" do
        agent_run.project.update!(
          model_preferences: { "excluded_model_ids" => [ low_model.model_id ] }
        )
        # Default complexity is 3.0 => low tier. Excluding low_model should
        # yield zero tier candidates, so the fallback pool is used instead.
        result = described_class.call(agent_run: agent_run)

        expect(result[:model]).not_to eq(low_model)
      end

      it "honors project-level threshold overrides" do
        # body > 1000 gives complexity 5.0 which is "mid" with defaults, but
        # with low_max=6 it falls into "low".
        agent_run.issue.update!(body: "A" * 1500)
        agent_run.project.update!(
          model_preferences: { "complexity_thresholds" => { "low_max" => 6, "mid_max" => 8 } }
        )

        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("low")
        expect(result[:model]).to eq(low_model)
      end

      it "honors runner-level threshold overrides on the agent run" do
        runner = create(:runner, user: agent_run.project.effective_owner)
        runner.update!(complexity_thresholds: { "low_max" => 2, "mid_max" => 9 })
        agent_run.update!(runner: runner)
        # Give enough body to bump complexity above low_max=2
        agent_run.issue.update!(body: "A" * 600)

        # Complexity 4.0 (body > 500) → above low_max=2, below mid_max=9 → "mid"
        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("mid")

        # Reconfigure so mid_max=3 ⇒ complexity 4.0 routes to high.
        runner.update!(complexity_thresholds: { "low_max" => 2, "mid_max" => 3 })
        agent_run.reload
        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("high")
      end

      it "falls back to the broader pool when the tier has no active models" do
        # The fallback path keeps the legacy capability floor (>= 8 for complex
        # tasks) so we provide an untiered high-capability model that survives
        # the floor when high-tier candidates are exhausted.
        untiered_high = create(:llm_model, model_id: "untiered-high", capability_score: 9.0)
        high_model.update!(active: false)
        # body > 3000 + existing_pr → complexity 8.0 > mid_max(7) → "high"
        agent_run.issue.update!(body: "A" * 5000)
        agent_run.update!(source_pull_request_number: 99)

        result = described_class.call(agent_run: agent_run)

        expect(result).to be_present
        expect(result[:tier]).to eq("high")
        expect(result[:model]).to eq(untiered_high)
      end
    end

    describe "runner tier_model_ids routing" do
      let!(:low_model)  { create(:llm_model, :cheap, model_id: "tier-low", tier: "low",  capability_score: 4.0) }
      let!(:mid_model)  { create(:llm_model,         model_id: "tier-mid", tier: "mid",  capability_score: 7.0) }
      let!(:custom_low) { create(:llm_model, :cheap, model_id: "custom-low", tier: "low", capability_score: 3.5) }

      before do
        LlmModel.where.not(id: [ low_model.id, mid_model.id, custom_low.id ]).destroy_all
      end

      it "prefers the runner's configured tier model over the global pool" do
        runner = create(:runner, user: agent_run.project.effective_owner,
          tier_model_ids: { "low" => custom_low.model_id })
        agent_run.update!(runner: runner)

        result = described_class.call(agent_run: agent_run)

        expect(result[:model]).to eq(custom_low)
      end

      it "falls back to global pool when runner tier model is inactive" do
        custom_low.update!(active: false)
        runner = create(:runner, user: agent_run.project.effective_owner,
          tier_model_ids: { "low" => custom_low.model_id })
        agent_run.update!(runner: runner)

        result = described_class.call(agent_run: agent_run)

        expect(result[:model]).to eq(low_model)
      end

      it "respects excluded_model_ids even for runner tier models" do
        runner = create(:runner, user: agent_run.project.effective_owner,
          tier_model_ids: { "low" => custom_low.model_id })
        agent_run.update!(runner: runner)
        agent_run.project.update!(
          model_preferences: { "excluded_model_ids" => [ custom_low.model_id ] }
        )

        result = described_class.call(agent_run: agent_run)

        expect(result[:model]).not_to eq(custom_low)
      end
    end

    describe "provider compatibility" do
      it "limits candidates to the selected provider family when no explicit tier pin exists" do
        anthropic_low = create(:llm_model, :cheap, model_id: "anthropic-low", provider: "anthropic", tier: "low", capability_score: 4.0)
        create(:llm_model, :cheap, model_id: "openai-low", provider: "openai", tier: "low", capability_score: 4.5)
        provider = agent_run.project.effective_owner.providers.find_by!(provider_key: "claude")
        agent_run.update!(provider: provider)

        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("low")
        expect(result[:model]).to eq(anthropic_low)
        expect(result[:candidates]).to all(have_attributes(provider: "anthropic"))
      end

      it "pins fixed-model Pi runs to the configured MiniMax model" do
        minimax_model = create(:llm_model, model_id: "MiniMax-M2.7", provider: "minimax", tier: "low", capability_score: 5.0)
        create(:llm_model, :cheap, model_id: "anthropic-low", provider: "anthropic", tier: "low", capability_score: 4.0)
        minimax_key = create(:provider_api_key, user: agent_run.project.effective_owner, api_service_type: "minimax")
        runner = create(
          :runner,
          user: agent_run.project.effective_owner,
          runner_key: "pi",
          auth_type: "api_key",
          provider_api_key: minimax_key,
          config: { "pi" => { "api_provider" => "minimax", "model" => minimax_model.model_id } }
        )
        agent_run.update!(runner: runner)

        result = described_class.call(agent_run: agent_run)

        expect(result[:tier]).to eq("low")
        expect(result[:model]).to eq(minimax_model)
        expect(result[:candidates]).to eq([ minimax_model ])
      end
    end
  end
end
