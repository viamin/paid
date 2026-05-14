# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::CalculateCompositeScore do
  def build_fake_quality_metric_class
    Class.new do
      def self.where(agent_run_id:)
        raise "unexpected agent_run_id: #{agent_run_id}" unless agent_run_id == 123

        [
          Struct.new(:scores).new({
            "focus_resolved" => 1.0,
            "ci_passed" => 1.0,
            "iterations" => 0.9
          })
        ]
      end

      def self.weights_for(goal:, focus:)
        raise "unexpected goal: #{goal}" unless goal == "create_pr"
        raise "unexpected focus: #{focus}" unless focus == "ci_fix"

        {
          "ci_passed" => 0.50,
          "lint_clean" => 0.20,
          "tests_pass" => 0.20,
          "iterations" => 0.10
        }
      end

      def self.weighted_average(scores_hash, weights:)
        total_weight = 0.0
        weighted_sum = 0.0

        scores_hash.each do |key, value|
          weight = weights[key]
          next unless weight

          total_weight += weight
          weighted_sum += weight * value.to_f
        end

        (weighted_sum / total_weight).round(4)
      end
    end
  end

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

      # create_pr weights: pr_created=0.25, ci_passed=0.15, iterations=0.10, lint_clean=0.05, tests_pass=0.05, pr_merged=0.25
      # Total weight: 0.25+0.15+0.10+0.05+0.05+0.25 = 0.85
      # Weighted: 0.25*1+0.15*1+0.10*0.8+0.05*1+0.05*1+0.25*1 = 0.25+0.15+0.08+0.05+0.05+0.25 = 0.83
      # 0.83 / 0.85 = 0.9765
      expect(score).to eq(0.9765)
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

      # create_pr weights: pr_created=0.25, ci_passed=0.15, total=0.40
      # Weighted: 0.25*1.0 + 0.15*0.0 = 0.25
      # 0.25/0.40 = 0.625
      expect(score).to eq(0.625)
    end

    it "uses focus-specific weights for focused create_pr runs" do
      agent_run = create(:agent_run, :completed, focus: "review_feedback")
      create(:quality_metric, :automated, agent_run: agent_run, scores: {
        "focus_resolved" => 1.0,
        "iterations" => 0.8,
        "lint_clean" => 1.0
      })

      score = described_class.call(agent_run: agent_run)

      expect(score).to eq(0.9556)
    end
  end

  describe "#calculate", :no_db do
    it "reads fresh metrics instead of a stale preloaded association cache" do
      stale_association = Struct.new(:to_a).new([])
      agent_run = Struct.new(:id, :goal, :focus, :quality_metrics)
        .new(123, "create_pr", "ci_fix", stale_association)
      stub_const("QualityMetric", build_fake_quality_metric_class)

      score = described_class.call(agent_run: agent_run)

      expect(score).to eq(0.9833)
    end
  end
end
