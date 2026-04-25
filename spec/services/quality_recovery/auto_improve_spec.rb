# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityRecovery::AutoImprove do
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project, goal: "create_pr", status: "completed") }
  let(:threshold) { create(:quality_threshold, account: project.account, project: project, min_value: 0.6) }
  let(:breach) do
    {
      threshold: threshold,
      average: 0.4,
      scores: [ 0.3, 0.4, 0.5 ],
      sample_size: 3
    }
  end

  describe "model escalation with per-goal tracking" do
    let(:window_size) { QualityThreshold::DEFAULT_WINDOW_SIZE }

    before do
      create(:quality_recovery_action,
        project: project,
        agent_run: agent_run,
        action_type: "prompt_evolution",
        status: "evaluated",
        quality_before: 0.4,
        quality_after: 0.35,
        executed_at: 2.hours.ago,
        evaluated_at: 1.hour.ago)

      create(:model_selection,
        agent_run: agent_run,
        llm_model: create(:llm_model, tier: "low"),
        tier: "low")

      # Create enough low-quality metrics so monitoring evaluates the prompt_evolution as failed
      window_size.times do
        run = create(:agent_run, project: project, goal: "create_pr", status: "completed")
        create(:quality_metric,
          agent_run: run,
          composite_score: 0.3,
          metric_type: "automated",
          created_at: 30.minutes.ago)
      end
    end

    it "stores the goal in escalation parameters" do
      described_class.call(agent_run: agent_run, breach: breach)

      action = project.quality_recovery_actions.where(action_type: "model_escalation").last
      expect(action).to be_present
      expect(action.parameters["goal"]).to eq("create_pr")
    end

    it "sets per-goal min tier in project preferences" do
      described_class.call(agent_run: agent_run, breach: breach)

      project.reload
      expect(project.model_preferences.dig("goal_min_tiers", "create_pr")).to eq("mid")
    end

    it "sets both project-wide and per-goal min tier" do
      described_class.call(agent_run: agent_run, breach: breach)

      project.reload
      expect(project.model_preferences["quality_recovery_min_tier"]).to eq("mid")
      expect(project.model_preferences.dig("goal_min_tiers", "create_pr")).to eq("mid")
    end
  end
end
