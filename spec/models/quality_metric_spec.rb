# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetric do
  describe "associations" do
    it { is_expected.to belong_to(:agent_run) }
    it { is_expected.to belong_to(:prompt_version).optional }
  end

  describe "validations" do
    subject(:quality_metric) { build(:quality_metric) }

    it { is_expected.to validate_presence_of(:metric_type) }
    it { is_expected.to validate_inclusion_of(:metric_type).in_array(described_class::METRIC_TYPES) }
    it { is_expected.to validate_uniqueness_of(:metric_type).scoped_to(:agent_run_id) }

    it {
      expect(quality_metric).to validate_numericality_of(:composite_score)
        .is_greater_than_or_equal_to(0)
        .is_less_than_or_equal_to(1)
        .allow_nil
    }
  end

  describe "scopes" do
    describe ".automated" do
      it "returns only automated metrics" do
        automated = create(:quality_metric, :automated)
        _human = create(:quality_metric, :human)

        expect(described_class.automated).to contain_exactly(automated)
      end
    end

    describe ".human" do
      it "returns only human metrics" do
        _automated = create(:quality_metric, :automated)
        human = create(:quality_metric, :human)

        expect(described_class.human).to contain_exactly(human)
      end
    end

    describe ".by_prompt_version" do
      it "filters by prompt version" do
        prompt = create(:prompt, :with_version)
        version = prompt.current_version
        matching = create(:quality_metric, prompt_version: version)
        _other = create(:quality_metric)

        expect(described_class.by_prompt_version(version.id)).to contain_exactly(matching)
      end
    end

    describe ".by_project" do
      it "filters by project through agent_run" do
        project = create(:project)
        agent_run = create(:agent_run, project: project)
        matching = create(:quality_metric, agent_run: agent_run)
        _other = create(:quality_metric)

        expect(described_class.by_project(project.id)).to contain_exactly(matching)
      end
    end

    describe ".by_time_period" do
      it "filters by created_at range" do
        old = create(:quality_metric)
        old.update_column(:created_at, 2.months.ago)
        recent = create(:quality_metric, :human)

        expect(described_class.by_time_period(1.month.ago, Time.current)).to contain_exactly(recent)
      end
    end

    describe ".with_composite_score" do
      it "excludes metrics without composite scores" do
        with_score = create(:quality_metric, composite_score: 0.85)
        _without_score = create(:quality_metric, :human, composite_score: nil)

        expect(described_class.with_composite_score).to contain_exactly(with_score)
      end
    end
  end

  describe "#calculate_composite_score" do
    it "calculates weighted average using goal-specific weights for create_pr" do
      agent_run = build(:agent_run, goal: "create_pr")
      metric = build(:quality_metric, agent_run: agent_run, scores: {
        "pr_created" => 1.0,
        "ci_passed" => 1.0,
        "iterations" => 0.8,
        "lint_clean" => 1.0,
        "tests_pass" => 1.0
      })

      score = metric.calculate_composite_score

      # create_pr weights: pr_created=0.25, ci_passed=0.15, iterations=0.10, lint_clean=0.05, tests_pass=0.05
      # (0.25*1.0 + 0.15*1.0 + 0.10*0.8 + 0.05*1.0 + 0.05*1.0) / 0.60 = 0.58/0.60
      expect(score).to eq(0.9667)
    end

    it "uses issue weights for create_issue goal" do
      agent_run = build(:agent_run, :create_issue_goal)
      metric = build(:quality_metric, agent_run: agent_run, scores: {
        "issue_created" => 1.0,
        "reaction_score" => 0.5
      })

      score = metric.calculate_composite_score

      # create_issue weights: issue_created=0.40, reaction_score=0.60
      # (0.40*1.0 + 0.60*0.5) / 1.0 = 0.7
      expect(score).to eq(0.7)
    end

    it "uses review weights for review goal" do
      agent_run = build(:agent_run, :review_goal)
      metric = build(:quality_metric, agent_run: agent_run, scores: {
        "review_posted" => 1.0,
        "reaction_score" => 0.8
      })

      score = metric.calculate_composite_score

      # review weights: review_posted=0.40, reaction_score=0.60
      # (0.40*1.0 + 0.60*0.8) / 1.0 = 0.88
      expect(score).to eq(0.88)
    end

    it "handles partial scores" do
      metric = build(:quality_metric, scores: { "pr_created" => 1.0 })

      score = metric.calculate_composite_score

      expect(score).to eq(1.0)
    end

    it "handles all-zero scores" do
      metric = build(:quality_metric, :low_quality)

      score = metric.calculate_composite_score

      expect(score).to eq(0.0)
    end

    it "returns nil for empty scores" do
      metric = build(:quality_metric, scores: {})

      expect(metric.calculate_composite_score).to be_nil
    end

    it "ignores unknown score keys" do
      metric = build(:quality_metric, scores: { "unknown_key" => 1.0 })

      expect(metric.calculate_composite_score).to be_nil
    end

    it "handles human feedback scores for PR goal" do
      metric = build(:quality_metric, :human, scores: { "pr_merged" => 1.0 })

      score = metric.calculate_composite_score

      # pr_merged has weight 0.25 in create_pr weights (default goal)
      expect(score).to eq(1.0)
    end
  end

  describe "#calculate_composite_score!" do
    it "persists the calculated score" do
      metric = create(:quality_metric, scores: { "pr_created" => 1.0, "ci_passed" => 0.0 }, composite_score: nil)

      metric.calculate_composite_score!

      # pr_created=0.25, ci_passed=0.15 -> (0.25*1.0 + 0.15*0.0) / 0.40 = 0.625
      expect(metric.reload.composite_score).to eq(0.625)
    end
  end
end
