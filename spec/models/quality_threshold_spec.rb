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

    it "accepts CI and test pass-rate thresholds" do
      expect(build(:quality_threshold, metric_type: "ci_passed")).to be_valid
      expect(build(:quality_threshold, metric_type: "tests_pass")).to be_valid
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

    it "requires valid severity" do
      threshold = build(:quality_threshold, :gate, severity: "extreme")

      expect(threshold).not_to be_valid
    end

    it "requires at least one of min_value or max_value" do
      threshold = build(:quality_threshold, :gate, min_value: nil, max_value: nil)

      expect(threshold).not_to be_valid
      expect(threshold.errors[:base]).to include("at least one threshold (min or max) must be set")
    end

    it "enforces uniqueness of metric_type per project for gate thresholds" do
      existing = create(:quality_threshold, :gate)
      duplicate = build(:quality_threshold, :gate,
        project: existing.project, metric_type: existing.metric_type)

      expect(duplicate).not_to be_valid
    end
  end

  describe ".effective_for" do
    it "returns built-in defaults when no records are configured" do
      project = create(:project)

      thresholds = described_class.effective_for(project: project, goal_type: "create_pr")

      expect(thresholds.map(&:metric_type)).to eq([ "composite_score" ])
    end

    it "lets account thresholds enable supported metrics" do
      project = create(:project)
      create(:quality_threshold,
        account: project.account,
        metric_type: "pr_merged",
        goal_type: "create_pr",
        min_value: 0.7)

      threshold = described_class.effective_for(project: project, goal_type: "create_pr")
        .find { |t| t.metric_type == "pr_merged" }

      expect(threshold.min_value).to eq(0.7)
      expect(threshold.source_scope).to eq("account")
    end

    it "lets project overrides replace account defaults" do
      project = create(:project)
      create(:quality_threshold,
        account: project.account,
        metric_type: "pr_merged",
        goal_type: "create_pr",
        min_value: 0.7)
      create(:quality_threshold, :project_override,
        project: project,
        metric_type: "pr_merged",
        goal_type: "create_pr",
        min_value: 0.8)

      threshold = described_class.effective_for(project: project, goal_type: "create_pr")
        .find { |t| t.metric_type == "pr_merged" }

      expect(threshold.min_value).to eq(0.8)
      expect(threshold.source_scope).to eq("project")
    end

    it "allows disabled project overrides to suppress inherited thresholds" do
      project = create(:project)
      create(:quality_threshold, :project_override, :disabled,
        project: project,
        metric_type: "pr_merged",
        goal_type: "create_pr")

      thresholds = described_class.effective_for(project: project, goal_type: "create_pr")

      expect(thresholds.map(&:metric_type)).not_to include("pr_merged")
    end
  end

  describe ".configurable_for" do
    it "returns rows for every collected metric and goal on a fresh project" do
      project = create(:project)

      thresholds = described_class.configurable_for(project: project)

      expect(thresholds.map { |threshold| [ threshold.metric_type, threshold.goal_type ] }).to include(
        [ "issue_created", "create_issue" ],
        [ "reaction_score", "create_issue" ],
        [ "lint_clean", "create_pr" ],
        [ "mutation_kill_rate", "create_pr" ],
        [ "review_comment_count", "create_pr" ],
        [ "review_posted", "review" ],
        [ "reaction_score", "review" ],
        [ "comment_posted", "enhance_issue" ],
        [ "author_replied", "enhance_issue" ],
        [ "question_count", "enhance_issue" ],
        [ "composite_score", "enhance_issue" ]
      )
    end

    it "omits valid metrics that do not yet collect pass and fail samples" do
      project = create(:project)

      thresholds = described_class.configurable_for(project: project)
      metric_keys = thresholds.map { |threshold| [ threshold.metric_type, threshold.goal_type ] }

      expect(metric_keys).not_to include(
        [ "ci_passed", "create_pr" ],
        [ "tests_pass", "create_pr" ],
        [ "pr_merged", "create_pr" ]
      )
    end

    it "marks only built-in defaults as enabled" do
      project = create(:project)

      thresholds = described_class.configurable_for(project: project)
      defaults = thresholds.select(&:default?)
      disabled_supported = thresholds.reject(&:enabled?)

      expect(defaults.map { |threshold| [ threshold.metric_type, threshold.goal_type, threshold.enabled? ] }).to include(
        [ "composite_score", "create_pr", true ]
      )
      expect(disabled_supported.map { |threshold| [ threshold.metric_type, threshold.goal_type ] }).to include(
        [ "lint_clean", "create_pr" ],
        [ "review_comment_count", "create_pr" ]
      )
    end

    it "overlays account defaults and project overrides on configurable rows" do
      project = create(:project)
      create(:quality_threshold,
        account: project.account,
        metric_type: "issue_created",
        goal_type: "create_issue",
        min_value: 0.6)
      create(:quality_threshold, :project_override,
        project: project,
        metric_type: "review_posted",
        goal_type: "review",
        min_value: 0.8)

      thresholds = described_class.configurable_for(project: project)
      account_threshold = thresholds.find { |threshold| threshold.metric_type == "issue_created" }
      project_threshold = thresholds.find { |threshold| threshold.metric_type == "review_posted" }

      expect(account_threshold.min_value).to eq(0.6)
      expect(account_threshold.source_scope).to eq("account")
      expect(project_threshold.min_value).to eq(0.8)
      expect(project_threshold.source_scope).to eq("project")
    end

    it "does not expose stored thresholds for unsupported metric and goal pairs" do
      project = create(:project)
      create(:quality_threshold,
        account: project.account,
        metric_type: "lint_clean",
        goal_type: "review")

      thresholds = described_class.configurable_for(project: project)

      expect(thresholds.map { |threshold| [ threshold.metric_type, threshold.goal_type ] }).not_to include(
        [ "lint_clean", "review" ]
      )
    end
  end

  describe "#breached?" do
    it "detects scores below the minimum value" do
      threshold = build(:quality_threshold, min_value: 0.5)

      expect(threshold.breached?(0.4)).to be true
      expect(threshold.breached?(0.5)).to be false
    end

    it "returns false for a nil score" do
      threshold = build(:quality_threshold, min_value: 0.5)

      expect(threshold.breached?(nil)).to be false
    end

    context "with a max_value ceiling (gate thresholds)" do
      let(:threshold) { build(:quality_threshold, :gate, :with_max, min_value: 0.5, max_value: 0.95) }

      it "returns true when the score is below the minimum" do
        expect(threshold.breached?(0.3)).to be true
      end

      it "returns true when the score is above the maximum" do
        expect(threshold.breached?(0.98)).to be true
      end

      it "returns false when the score is within range" do
        expect(threshold.breached?(0.7)).to be false
      end
    end
  end

  describe "#breached_value" do
    let(:threshold) { build(:quality_threshold, :gate, :with_max, min_value: 0.5, max_value: 0.95) }

    it "returns min_value when the score is below it" do
      expect(threshold.breached_value(0.3)).to eq(0.5)
    end

    it "returns max_value when the score is above it" do
      expect(threshold.breached_value(0.98)).to eq(0.95)
    end

    it "returns nil when not breached" do
      expect(threshold.breached_value(0.7)).to be_nil
    end
  end

  describe "gate thresholds" do
    it "are excluded from .effective_for regardless of goal_type filter" do
      project = create(:project)
      create(:quality_threshold, :gate, project: project, metric_type: "lint_clean", min_value: 0.9)

      expect(described_class.effective_for(project: project).map(&:metric_type)).not_to include("lint_clean")
      expect(described_class.effective_for(project: project, goal_type: "create_pr").map(&:metric_type))
        .not_to include("lint_clean")
    end

    it "are excluded from .configurable_for" do
      project = create(:project)
      create(:quality_threshold, :gate, project: project, metric_type: "lint_clean", min_value: 0.9)

      thresholds = described_class.configurable_for(project: project)

      expect(thresholds.map { |threshold| [ threshold.metric_type, threshold.goal_type ] })
        .not_to include([ "lint_clean", QualityThreshold::ALL_GOALS ])
    end
  end
end
