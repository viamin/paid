# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityRecovery::ModelEscalation do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }
  let!(:mid_model) { create(:llm_model, model_id: "mid-model", tier: "mid", capability_score: 7.0) }
  let!(:high_model) { create(:llm_model, model_id: "high-model", tier: "high", capability_score: 9.5) }

  let(:threshold_obj) { Struct.new(:min_value).new(0.5) }
  let(:breach) { { average: 0.35, threshold: threshold_obj } }

  describe ".start" do
    context "when no escalation is active" do
      before do
        create(:model_selection, agent_run: agent_run, tier: "mid", llm_model: mid_model)
      end

      it "starts escalation and records the action" do
        result = described_class.start(project: project, agent_run: agent_run, breach: breach)

        expect(result).to be_started
        expect(result).to be_defer_pause
        expect(result.state["status"]).to eq("active")
        expect(result.state["from_tier"]).to eq("mid")
        expect(result.state["to_tier"]).to eq("high")
      end

      it "persists escalation state in project model_preferences" do
        described_class.start(project: project, agent_run: agent_run, breach: breach)

        project.reload
        state = project.model_preferences["quality_triggered_escalation"]
        expect(state["status"]).to eq("active")
        expect(state["trigger"]).to eq("quality_drop")
      end

      it "creates a quality recovery action record" do
        expect {
          described_class.start(project: project, agent_run: agent_run, breach: breach)
        }.to change(QualityRecoveryAction, :count).by(1)
      end
    end

    context "when escalation is already active" do
      before do
        project.update!(model_preferences: {
          "quality_triggered_escalation" => {
            "status" => "active",
            "from_tier" => "mid",
            "to_tier" => "high"
          }
        })
      end

      it "does not start a new escalation" do
        result = described_class.start(project: project, agent_run: agent_run, breach: breach)

        expect(result).not_to be_started
        expect(result.reason).to eq("already_active")
      end
    end

    context "when already at the highest tier" do
      before do
        create(:model_selection, agent_run: agent_run, tier: "high", llm_model: high_model)
      end

      it "does not start escalation (no higher tier available)" do
        result = described_class.start(project: project, agent_run: agent_run, breach: breach)

        expect(result).not_to be_started
        expect(result.reason).to eq("no_higher_tier")
        expect(result).to be_pause
      end
    end

    context "when escalation was previously exhausted" do
      before do
        project.update!(model_preferences: {
          "quality_triggered_escalation" => { "status" => "exhausted" }
        })
      end

      it "does not restart escalation" do
        result = described_class.start(project: project, agent_run: agent_run, breach: breach)

        expect(result).not_to be_started
        expect(result.reason).to eq("quality_recovery_exhausted")
        expect(result).to be_pause
      end
    end
  end

  describe ".active?" do
    it "returns true when status is active" do
      project.update!(model_preferences: {
        "quality_triggered_escalation" => { "status" => "active" }
      })

      expect(described_class.active?(project)).to be true
    end

    it "returns true when prompt_evolution_requested" do
      project.update!(model_preferences: {
        "quality_triggered_escalation" => { "status" => "prompt_evolution_requested" }
      })

      expect(described_class.active?(project)).to be true
    end

    it "returns false when exhausted" do
      project.update!(model_preferences: {
        "quality_triggered_escalation" => { "status" => "exhausted" }
      })

      expect(described_class.active?(project)).to be false
    end

    it "returns false when no escalation state exists" do
      expect(described_class.active?(project)).to be false
    end
  end

  describe ".target_tier" do
    it "returns the to_tier when escalation is active" do
      project.update!(model_preferences: {
        "quality_triggered_escalation" => {
          "status" => "active",
          "to_tier" => "high"
        }
      })

      expect(described_class.target_tier(project)).to eq("high")
    end

    it "returns nil when escalation is not active" do
      expect(described_class.target_tier(project)).to be_nil
    end
  end

  describe ".evaluate" do
    let(:escalation_started_at) { 1.hour.ago.iso8601 }

    context "when escalation is active with sufficient passing samples" do
      before do
        project.update!(model_preferences: {
          "quality_triggered_escalation" => {
            "status" => "active",
            "goal" => agent_run.goal,
            "from_tier" => "mid",
            "to_tier" => "high",
            "started_at" => escalation_started_at,
            "threshold" => 0.5,
            "evaluation_window" => 3
          }
        })

        3.times do
          run = create(:agent_run, project: project, goal: agent_run.goal)
          create(:model_selection, agent_run: run, selector_type: "quality_escalation", tier: "high", llm_model: high_model)
          create(:quality_metric, agent_run: run, composite_score: 0.8)
        end
      end

      it "recovers when escalated runs meet the threshold" do
        result = described_class.evaluate(project: project, agent_run: agent_run)

        expect(result.reason).to eq("model_escalation_recovered")
        project.reload
        expect(project.model_preferences.dig("quality_triggered_escalation", "status")).to eq("recovered")
      end
    end

    context "when escalation is active with insufficient samples" do
      before do
        project.update!(model_preferences: {
          "quality_triggered_escalation" => {
            "status" => "active",
            "goal" => agent_run.goal,
            "from_tier" => "mid",
            "to_tier" => "high",
            "started_at" => escalation_started_at,
            "threshold" => 0.5,
            "evaluation_window" => 3
          }
        })

        run = create(:agent_run, project: project, goal: agent_run.goal)
        create(:model_selection, agent_run: run, selector_type: "quality_escalation", tier: "high", llm_model: high_model)
        create(:quality_metric, agent_run: run, composite_score: 0.8)
      end

      it "keeps escalation active while waiting for more samples" do
        result = described_class.evaluate(project: project, agent_run: agent_run)

        expect(result.reason).to eq("model_escalation_active")
        expect(result).to be_defer_pause
      end
    end

    context "when escalation is active but quality still fails" do
      before do
        project.update!(model_preferences: {
          "quality_triggered_escalation" => {
            "status" => "active",
            "goal" => agent_run.goal,
            "from_tier" => "mid",
            "to_tier" => "high",
            "started_at" => escalation_started_at,
            "threshold" => 0.5,
            "evaluation_window" => 3,
            "prompt_id" => 999
          }
        })

        3.times do
          run = create(:agent_run, project: project, goal: agent_run.goal)
          create(:model_selection, agent_run: run, selector_type: "quality_escalation", tier: "high", llm_model: high_model)
          create(:quality_metric, agent_run: run, composite_score: 0.3)
        end
      end

      it "requests prompt evolution" do
        result = described_class.evaluate(project: project, agent_run: agent_run)

        expect(result.reason).to eq("prompt_evolution_requested")
        project.reload
        expect(project.model_preferences.dig("quality_triggered_escalation", "status")).to eq("prompt_evolution_requested")
      end
    end
  end
end
