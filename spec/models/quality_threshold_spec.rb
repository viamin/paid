# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityThreshold do
  describe "validations" do
    it "accepts account default thresholds" do
      threshold = build(:quality_threshold, project: nil)

      expect(threshold).to be_valid
    end

    it "assigns account from the project override" do
      project = create(:project)
      threshold = build(:quality_threshold, :project_override, project: project, account: nil)

      expect(threshold).to be_valid
      expect(threshold.account).to eq(project.account)
    end

    it "rejects projects from a different account" do
      threshold = build(:quality_threshold, :project_override, account: create(:account))

      expect(threshold).not_to be_valid
      expect(threshold.errors[:project]).to include("must belong to the same account")
    end

    it "validates sensible threshold ranges" do
      threshold = build(:quality_threshold, min_value: 1.2)

      expect(threshold).not_to be_valid
    end

    it "enforces one threshold per account metric and goal" do
      existing = create(:quality_threshold)
      duplicate = build(:quality_threshold,
        account: existing.account,
        metric_type: existing.metric_type,
        goal_type: existing.goal_type)

      expect(duplicate).not_to be_valid
    end

    it "enforces one threshold per project metric and goal" do
      existing = create(:quality_threshold, :project_override)
      duplicate = build(:quality_threshold, :project_override,
        project: existing.project,
        metric_type: existing.metric_type,
        goal_type: existing.goal_type)

      expect(duplicate).not_to be_valid
    end
  end

  describe ".effective_for" do
    it "returns built-in defaults when no records are configured" do
      project = create(:project)

      thresholds = described_class.effective_for(project: project, goal_type: "create_pr")

      expect(thresholds.map(&:metric_type)).to include("ci_passed", "pr_merged")
    end

    it "lets account thresholds override built-in defaults" do
      project = create(:project)
      create(:quality_threshold,
        account: project.account,
        metric_type: "ci_passed",
        goal_type: "create_pr",
        min_value: 0.7)

      threshold = described_class.effective_for(project: project, goal_type: "create_pr")
        .find { |t| t.metric_type == "ci_passed" }

      expect(threshold.min_value).to eq(0.7)
      expect(threshold.source_scope).to eq("account")
    end

    it "lets project overrides replace account defaults" do
      project = create(:project)
      create(:quality_threshold,
        account: project.account,
        metric_type: "ci_passed",
        goal_type: "create_pr",
        min_value: 0.7)
      create(:quality_threshold, :project_override,
        project: project,
        metric_type: "ci_passed",
        goal_type: "create_pr",
        min_value: 0.8)

      threshold = described_class.effective_for(project: project, goal_type: "create_pr")
        .find { |t| t.metric_type == "ci_passed" }

      expect(threshold.min_value).to eq(0.8)
      expect(threshold.source_scope).to eq("project")
    end

    it "allows disabled project overrides to suppress inherited thresholds" do
      project = create(:project)
      create(:quality_threshold, :project_override, :disabled,
        project: project,
        metric_type: "ci_passed",
        goal_type: "create_pr")

      thresholds = described_class.effective_for(project: project, goal_type: "create_pr")

      expect(thresholds.map(&:metric_type)).not_to include("ci_passed")
    end
  end

  describe "#breached?" do
    it "detects scores below the minimum value" do
      threshold = build(:quality_threshold, min_value: 0.5)

      expect(threshold.breached?(0.4)).to be true
      expect(threshold.breached?(0.5)).to be false
    end
  end
end
