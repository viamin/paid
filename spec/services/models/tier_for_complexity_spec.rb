# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::TierForComplexity do
  describe ".call" do
    it "returns nil when complexity is nil" do
      expect(described_class.call(complexity: nil)).to be_nil
    end

    it "returns nil when complexity is non-numeric" do
      expect(described_class.call(complexity: "not-a-number")).to be_nil
    end

    it "maps low complexity to the low tier using defaults" do
      expect(described_class.call(complexity: 1)).to eq("low")
      expect(described_class.call(complexity: 3)).to eq("low")
    end

    it "maps mid complexity to the mid tier using defaults" do
      expect(described_class.call(complexity: 4)).to eq("mid")
      expect(described_class.call(complexity: 7)).to eq("mid")
    end

    it "maps high complexity to the high tier using defaults" do
      expect(described_class.call(complexity: 8)).to eq("high")
      expect(described_class.call(complexity: 10)).to eq("high")
    end

    it "uses runner thresholds when provided" do
      runner = build(:runner, complexity_thresholds: { "low_max" => 5, "mid_max" => 8 })
      expect(described_class.call(complexity: 5, runner: runner)).to eq("low")
      expect(described_class.call(complexity: 6, runner: runner)).to eq("mid")
      expect(described_class.call(complexity: 9, runner: runner)).to eq("high")
    end

    it "prefers project overrides over runner thresholds" do
      runner = build(:runner, complexity_thresholds: { "low_max" => 5, "mid_max" => 8 })
      project = build(:project)
      project.model_preferences = { "complexity_thresholds" => { "low_max" => 1, "mid_max" => 2 } }

      expect(described_class.call(complexity: 3, runner: runner, project: project)).to eq("high")
    end

    context "with per-goal min tier" do
      it "raises tier to per-goal minimum" do
        project = build(:project)
        project.model_preferences = { "goal_min_tiers" => { "create_pr" => "high" } }

        expect(described_class.call(complexity: 2, project: project, goal: "create_pr")).to eq("high")
      end

      it "does not affect other goals" do
        project = build(:project)
        project.model_preferences = { "goal_min_tiers" => { "create_pr" => "high" } }

        expect(described_class.call(complexity: 2, project: project, goal: "review")).to eq("low")
      end

      it "prefers per-goal min tier over project-wide min tier" do
        project = build(:project)
        project.model_preferences = {
          "quality_recovery_min_tier" => "mid",
          "goal_min_tiers" => { "create_pr" => "high" }
        }

        expect(described_class.call(complexity: 2, project: project, goal: "create_pr")).to eq("high")
      end

      it "falls back to project-wide min tier when no goal tier is set" do
        project = build(:project)
        project.model_preferences = {
          "quality_recovery_min_tier" => "mid",
          "goal_min_tiers" => {}
        }

        expect(described_class.call(complexity: 2, project: project, goal: "review")).to eq("mid")
      end

      it "respects max_tier cap even with per-goal escalation" do
        project = build(:project)
        project.model_preferences = {
          "goal_min_tiers" => { "create_pr" => "high" },
          "max_tier" => "mid"
        }

        expect(described_class.call(complexity: 2, project: project, goal: "create_pr")).to eq("mid")
      end
    end

    context "with max_tier project preference" do
      it "raises lower complexity tiers to the quality recovery minimum tier" do
        project = build(:project)
        project.model_preferences = { "quality_recovery_min_tier" => "high" }

        expect(described_class.call(complexity: 2, project: project)).to eq("high")
      end

      it "caps high tier to mid when max_tier is mid" do
        project = build(:project)
        project.model_preferences = { "max_tier" => "mid" }

        expect(described_class.call(complexity: 9, project: project)).to eq("mid")
      end

      it "does not affect tiers at or below the cap" do
        project = build(:project)
        project.model_preferences = { "max_tier" => "mid" }

        expect(described_class.call(complexity: 2, project: project)).to eq("low")
        expect(described_class.call(complexity: 5, project: project)).to eq("mid")
      end

      it "caps to low when max_tier is low" do
        project = build(:project)
        project.model_preferences = { "max_tier" => "low" }

        expect(described_class.call(complexity: 9, project: project)).to eq("low")
        expect(described_class.call(complexity: 5, project: project)).to eq("low")
      end

      it "ignores invalid max_tier values" do
        project = build(:project)
        project.model_preferences = { "max_tier" => "invalid" }

        expect(described_class.call(complexity: 9, project: project)).to eq("high")
      end

      it "ignores blank max_tier" do
        project = build(:project)
        project.model_preferences = { "max_tier" => "" }

        expect(described_class.call(complexity: 9, project: project)).to eq("high")
      end
    end
  end
end
