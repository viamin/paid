# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::LearnEscalationDefaults do
  describe ".call" do
    let(:project) { create(:project) }
    let!(:llm_model) { create(:llm_model, tier: "mid") }

    def create_escalated_run(goal:, tier:, from_tier:, created_at: Time.current)
      agent_run = create(:agent_run, project: project, goal: goal, status: "completed")
      create(:model_selection,
        agent_run: agent_run,
        llm_model: llm_model,
        tier: tier,
        escalated_from_tier: from_tier,
        escalated_reason: "quality_recovery_project",
        created_at: created_at)
      agent_run
    end

    context "when a goal has enough escalation history" do
      before do
        3.times { create_escalated_run(goal: "create_pr", tier: "mid", from_tier: "low") }
      end

      it "sets the learned min tier for that goal" do
        described_class.call(project: project)

        project.reload
        expect(project.model_preferences.dig("goal_min_tiers", "create_pr")).to eq("mid")
      end

      it "returns true when preferences were updated" do
        expect(described_class.call(project: project)).to be true
      end
    end

    context "when escalation count is below threshold" do
      before do
        2.times { create_escalated_run(goal: "create_pr", tier: "mid", from_tier: "low") }
      end

      it "does not set a min tier" do
        described_class.call(project: project)

        project.reload
        expect(project.model_preferences.dig("goal_min_tiers", "create_pr")).to be_nil
      end

      it "returns false" do
        expect(described_class.call(project: project)).to be false
      end
    end

    context "when escalations are outside the lookback window" do
      before do
        3.times do
          create_escalated_run(goal: "create_pr", tier: "mid", from_tier: "low", created_at: 31.days.ago)
        end
      end

      it "does not count old escalations" do
        described_class.call(project: project)

        project.reload
        expect(project.model_preferences.dig("goal_min_tiers", "create_pr")).to be_nil
      end
    end

    context "when goal already has a higher learned tier" do
      before do
        project.update!(model_preferences: { "goal_min_tiers" => { "create_pr" => "high" } })
        3.times { create_escalated_run(goal: "create_pr", tier: "mid", from_tier: "low") }
      end

      it "does not downgrade the existing min tier" do
        described_class.call(project: project)

        project.reload
        expect(project.model_preferences.dig("goal_min_tiers", "create_pr")).to eq("high")
      end
    end

    context "with multiple goals" do
      before do
        3.times { create_escalated_run(goal: "create_pr", tier: "mid", from_tier: "low") }
        3.times { create_escalated_run(goal: "create_issue", tier: "high", from_tier: "mid") }
      end

      it "learns independently per goal" do
        described_class.call(project: project)

        project.reload
        expect(project.model_preferences.dig("goal_min_tiers", "create_pr")).to eq("mid")
        expect(project.model_preferences.dig("goal_min_tiers", "create_issue")).to eq("high")
      end
    end
  end
end
