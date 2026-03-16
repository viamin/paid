# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::CalculateCompositeScore do
  describe ".call" do
    it "merges automated and human scores into a composite" do
      agent_run = create(:agent_run, :completed)
      create(:quality_metric, :automated, agent_run: agent_run, scores: {
        "pr_created" => 1.0,
        "ci_passed" => 1.0,
        "iterations" => 0.8,
        "lint_clean" => 1.0,
        "tests_pass" => 1.0
      })
      create(:quality_metric, :human, agent_run: agent_run, scores: {
        "pr_merged" => 1.0
      })

      score = described_class.call(agent_run: agent_run)

      # All weights: 0.30+0.20+0.15+0.10+0.05+0.30 = 1.10 (all applicable)
      # Weighted: 0.30*1+0.20*1+0.15*0.8+0.10*1+0.05*1+0.30*1 = 0.30+0.20+0.12+0.10+0.05+0.30 = 1.07
      # 1.07 / 1.10 = 0.9727
      expect(score).to eq(0.9727)
    end

    it "returns nil when no quality metrics exist" do
      agent_run = create(:agent_run, :completed)

      score = described_class.call(agent_run: agent_run)

      expect(score).to be_nil
    end

    it "handles automated-only metrics" do
      agent_run = create(:agent_run, :completed)
      create(:quality_metric, :automated, agent_run: agent_run, scores: {
        "pr_created" => 1.0,
        "ci_passed" => 0.0
      })

      score = described_class.call(agent_run: agent_run)

      # Weights: pr_created=0.30, ci_passed=0.20, total=0.50
      # Weighted: 0.30*1.0 + 0.20*0.0 = 0.30
      # 0.30/0.50 = 0.6
      expect(score).to eq(0.6)
    end
  end
end
