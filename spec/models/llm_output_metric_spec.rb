# frozen_string_literal: true

require "rails_helper"

RSpec.describe LlmOutputMetric do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:prompt_version).optional }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:output_type) }
    it { is_expected.to validate_inclusion_of(:output_type).in_array(described_class::OUTPUT_TYPES) }
    it { is_expected.to validate_presence_of(:prompt_slug) }
    it { is_expected.to validate_presence_of(:source_id) }
    it { is_expected.to validate_presence_of(:source_type) }
    it { is_expected.to validate_inclusion_of(:source_type).in_array(described_class::SOURCE_TYPES) }

    it {
      expect(build(:llm_output_metric)).to validate_numericality_of(:composite_score)
        .is_greater_than_or_equal_to(0)
        .is_less_than_or_equal_to(1)
        .allow_nil
    }

    it "enforces uniqueness of source_id scoped to project, output_type, and source_type" do
      existing = create(:llm_output_metric)
      duplicate = build(:llm_output_metric,
        project: existing.project,
        output_type: existing.output_type,
        source_type: existing.source_type,
        source_id: existing.source_id)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:source_id]).to be_present
    end
  end

  describe "scopes" do
    describe ".by_output_type" do
      it "filters by output type" do
        pr = create(:llm_output_metric, :pr_description)
        _issue = create(:llm_output_metric, :issue_title)

        expect(described_class.by_output_type("pr_description")).to contain_exactly(pr)
      end
    end

    describe ".by_prompt_slug" do
      it "filters by prompt slug" do
        pr = create(:llm_output_metric, prompt_slug: "generation.pr_description")
        _other = create(:llm_output_metric, prompt_slug: "generation.issue_title", output_type: "issue_title", source_type: "Issue")

        expect(described_class.by_prompt_slug("generation.pr_description")).to contain_exactly(pr)
      end
    end

    describe ".for_source" do
      it "filters by source type and id" do
        metric = create(:llm_output_metric, source_type: "PullRequest", source_id: 42)
        _other = create(:llm_output_metric, source_type: "PullRequest", source_id: 99)

        expect(described_class.for_source("PullRequest", 42)).to contain_exactly(metric)
      end
    end

    describe ".with_composite_score" do
      it "excludes nil composite scores" do
        with_score = create(:llm_output_metric, composite_score: 0.85)
        _without = create(:llm_output_metric, composite_score: nil)

        expect(described_class.with_composite_score).to contain_exactly(with_score)
      end
    end
  end

  describe "#calculate_composite_score" do
    it "calculates weighted average for pr_description" do
      metric = build(:llm_output_metric, :pr_description, scores: {
        "description_edited" => 1.0,
        "description_length_ratio" => 0.8,
        "pr_reaction" => 1.0
      })

      score = metric.calculate_composite_score
      # (1.0*0.50 + 0.8*0.20 + 1.0*0.30) / (0.50 + 0.20 + 0.30) = 0.96
      expect(score).to eq(0.96)
    end

    it "calculates weighted average for issue_title" do
      metric = build(:llm_output_metric, :issue_title, scores: {
        "title_edited" => 1.0,
        "issue_reaction" => 0.5
      })

      score = metric.calculate_composite_score
      # (1.0*0.60 + 0.5*0.40) / 1.0 = 0.8
      expect(score).to eq(0.8)
    end

    it "calculates weighted average for decision_record" do
      metric = build(:llm_output_metric, :decision_record, scores: {
        "record_kept" => 1.0,
        "tag_count" => 0.6667
      })

      score = metric.calculate_composite_score
      # (1.0*0.60 + 0.6667*0.40) / 1.0 = 0.8667
      expect(score).to eq(0.8667)
    end

    it "returns nil when no weighted scores exist" do
      metric = build(:llm_output_metric, scores: { "unknown_key" => 1.0 })
      expect(metric.calculate_composite_score).to be_nil
    end

    it "returns nil when scores are empty" do
      metric = build(:llm_output_metric, scores: {})
      expect(metric.calculate_composite_score).to be_nil
    end
  end

  describe "#calculate_composite_score!" do
    it "persists the calculated composite score" do
      metric = create(:llm_output_metric, :pr_description, scores: {
        "description_edited" => 1.0,
        "description_length_ratio" => 1.0,
        "pr_reaction" => 1.0
      })

      metric.calculate_composite_score!
      expect(metric.reload.composite_score).to eq(1.0)
    end
  end
end
