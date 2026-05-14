# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::OutcomeImprovement, :no_db do
  let(:project) { double(id: 42) }

  def make_row(quality_score:, cost_cents:, success:, objective_score:, quality_per_dollar: nil, selection_mode: nil)
    {
      quality_score: quality_score,
      cost_cents: cost_cents,
      success: success,
      objective_score: objective_score,
      quality_per_dollar: quality_per_dollar,
      selection_mode: selection_mode,
      created_at: Time.current
    }
  end

  describe "with insufficient data" do
    it "returns insufficient data result when there are fewer than 4 outcomes" do
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return([
        make_row(quality_score: 0.8, cost_cents: 100, success: true, objective_score: 0.7, selection_mode: "exploitative"),
        make_row(quality_score: 0.7, cost_cents: 80, success: true, objective_score: 0.65, selection_mode: "exploitative"),
        make_row(quality_score: 0.75, cost_cents: 90, success: true, objective_score: 0.68, selection_mode: "exploratory")
      ])

      result = service.call

      expect(result.sufficient_data).to be false
      expect(result.outcome_count).to eq(3)
      expect(result.objective_improvement).to be_nil
      expect(result.periods).to be_empty
    end

    it "returns insufficient data result when there are no outcomes" do
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return([])

      result = service.call

      expect(result.sufficient_data).to be false
      expect(result.outcome_count).to eq(0)
    end
  end

  describe "with sufficient data" do
    let(:improving_rows) do
      [
        make_row(quality_score: 0.5, cost_cents: 200, success: true, objective_score: 0.45, quality_per_dollar: 0.25, selection_mode: "exploitative"),
        make_row(quality_score: 0.55, cost_cents: 180, success: true, objective_score: 0.50, quality_per_dollar: 0.306, selection_mode: "exploratory"),
        make_row(quality_score: 0.6, cost_cents: 160, success: true, objective_score: 0.55, quality_per_dollar: 0.375, selection_mode: "exploitative"),
        make_row(quality_score: 0.75, cost_cents: 140, success: true, objective_score: 0.70, quality_per_dollar: 0.536, selection_mode: "exploitative"),
        make_row(quality_score: 0.8, cost_cents: 120, success: true, objective_score: 0.75, quality_per_dollar: 0.667, selection_mode: "exploitative"),
        make_row(quality_score: 0.85, cost_cents: 100, success: true, objective_score: 0.80, quality_per_dollar: 0.85, selection_mode: "exploitative")
      ]
    end

    it "returns sufficient data result" do
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(improving_rows)

      result = service.call

      expect(result.sufficient_data).to be true
      expect(result.outcome_count).to eq(6)
    end

    it "computes objective improvement between early and recent periods" do
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(improving_rows)

      result = service.call

      expect(result.early_objective_score).to be_within(0.01).of(0.50)
      expect(result.recent_objective_score).to be_within(0.01).of(0.75)
      expect(result.objective_improvement).to be > 0
    end

    it "computes quality improvement between early and recent periods" do
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(improving_rows)

      result = service.call

      expect(result.early_quality_score).to be_within(0.01).of(0.55)
      expect(result.recent_quality_score).to be_within(0.01).of(0.8)
      expect(result.quality_improvement).to be > 0
    end

    it "computes cost change between early and recent periods" do
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(improving_rows)

      result = service.call

      expect(result.early_cost_cents).to be_within(1).of(180)
      expect(result.recent_cost_cents).to be_within(1).of(120)
      expect(result.cost_change_fraction).to be < 0
    end

    it "computes quality-per-dollar improvement" do
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(improving_rows)

      result = service.call

      expect(result.recent_quality_per_dollar).to be > result.early_quality_per_dollar
      expect(result.quality_per_dollar_improvement).to be > 0
    end

    it "tracks exploitative vs exploratory outcomes" do
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(improving_rows)

      result = service.call

      expect(result.exploitative_sample_count).to eq(5)
      expect(result.exploratory_sample_count).to eq(1)
    end

    it "computes optimizer learning ratio" do
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(improving_rows)

      result = service.call

      expect(result.optimizer_learning_ratio).not_to be_nil
    end

    it "builds period snapshots" do
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(improving_rows)

      result = service.call

      expect(result.periods.length).to be >= 2
      expect(result.periods.first).to be_a(described_class::PeriodSnapshot)
      expect(result.periods.first.outcome_count).to be > 0
      expect(result.periods.first.avg_objective_score).not_to be_nil
    end
  end

  describe "quality-per-dollar fallback" do
    it "computes quality-per-dollar from quality and cost when metrics lack it" do
      rows = [
        make_row(quality_score: 0.5, cost_cents: 100, success: true, objective_score: 0.45),
        make_row(quality_score: 0.6, cost_cents: 100, success: true, objective_score: 0.55),
        make_row(quality_score: 0.8, cost_cents: 200, success: true, objective_score: 0.75),
        make_row(quality_score: 0.9, cost_cents: 200, success: true, objective_score: 0.85)
      ]
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(rows)

      result = service.call

      expect(result.early_quality_per_dollar).not_to be_nil
      expect(result.recent_quality_per_dollar).not_to be_nil
      expect(result.early_quality_per_dollar).to be_within(0.01).of(0.55)
      expect(result.recent_quality_per_dollar).to be_within(0.01).of(0.425)
    end
  end

  describe "optimizer learning ratio" do
    it "returns nil when there are no exploratory runs" do
      rows = 6.times.map do |i|
        make_row(quality_score: 0.7 + i * 0.05, cost_cents: 100, success: true, objective_score: 0.65 + i * 0.05, selection_mode: "exploitative")
      end
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(rows)

      result = service.call

      expect(result.optimizer_learning_ratio).to be_nil
      expect(result.exploratory_sample_count).to eq(0)
    end

    it "returns nil when there are no exploitative runs" do
      rows = 4.times.map do |i|
        make_row(quality_score: 0.7 + i * 0.05, cost_cents: 100, success: true, objective_score: 0.65 + i * 0.05, selection_mode: "exploratory")
      end
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(rows)

      result = service.call

      expect(result.optimizer_learning_ratio).to be_nil
      expect(result.exploitative_sample_count).to eq(0)
    end

    it "returns a positive ratio when exploitative outperforms exploratory" do
      rows = [
        make_row(quality_score: 0.5, cost_cents: 100, success: true, objective_score: 0.45, selection_mode: "exploratory"),
        make_row(quality_score: 0.55, cost_cents: 100, success: true, objective_score: 0.50, selection_mode: "exploratory"),
        make_row(quality_score: 0.85, cost_cents: 100, success: true, objective_score: 0.80, selection_mode: "exploitative"),
        make_row(quality_score: 0.9, cost_cents: 100, success: true, objective_score: 0.85, selection_mode: "exploitative")
      ]
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(rows)

      result = service.call

      expect(result.optimizer_learning_ratio).to be > 0
    end

    it "returns a negative ratio when exploratory outperforms exploitative" do
      rows = [
        make_row(quality_score: 0.9, cost_cents: 100, success: true, objective_score: 0.85, selection_mode: "exploratory"),
        make_row(quality_score: 0.85, cost_cents: 100, success: true, objective_score: 0.80, selection_mode: "exploratory"),
        make_row(quality_score: 0.5, cost_cents: 100, success: true, objective_score: 0.45, selection_mode: "exploitative"),
        make_row(quality_score: 0.55, cost_cents: 100, success: true, objective_score: 0.50, selection_mode: "exploitative")
      ]
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(rows)

      result = service.call

      expect(result.optimizer_learning_ratio).to be < 0
    end
  end

  describe "period snapshots" do
    it "divides outcomes into approximately equal periods" do
      rows = 8.times.map do |i|
        make_row(quality_score: 0.5 + i * 0.05, cost_cents: 200 - i * 20, success: true, objective_score: 0.45 + i * 0.05)
      end
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(rows)

      result = service.call

      expect(result.periods.length).to eq(2)
      expect(result.periods.map(&:outcome_count).sum).to eq(8)
    end

    it "computes success rate per period" do
      rows = [
        make_row(quality_score: 0.5, cost_cents: 100, success: true, objective_score: 0.45),
        make_row(quality_score: 0.5, cost_cents: 100, success: false, objective_score: 0.45),
        make_row(quality_score: 0.9, cost_cents: 100, success: true, objective_score: 0.85),
        make_row(quality_score: 0.9, cost_cents: 100, success: true, objective_score: 0.85)
      ]
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(rows)

      result = service.call

      expect(result.periods.first.success_rate).to eq(0.5)
      expect(result.periods.last.success_rate).to eq(1.0)
    end

    it "shows improving trend across periods" do
      rows = [
        make_row(quality_score: 0.5, cost_cents: 200, success: true, objective_score: 0.45),
        make_row(quality_score: 0.5, cost_cents: 200, success: true, objective_score: 0.45),
        make_row(quality_score: 0.9, cost_cents: 100, success: true, objective_score: 0.85),
        make_row(quality_score: 0.9, cost_cents: 100, success: true, objective_score: 0.85)
      ]
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(rows)

      result = service.call

      expect(result.periods.last.avg_objective_score).to be > result.periods.first.avg_objective_score
      expect(result.periods.last.avg_cost_cents).to be < result.periods.first.avg_cost_cents
    end
  end

  describe "edge cases" do
    it "handles nil objective scores gracefully" do
      rows = [
        make_row(quality_score: 0.5, cost_cents: 100, success: true, objective_score: nil, selection_mode: "exploitative"),
        make_row(quality_score: 0.6, cost_cents: 100, success: true, objective_score: nil, selection_mode: "exploitative"),
        make_row(quality_score: 0.7, cost_cents: 100, success: true, objective_score: nil, selection_mode: "exploitative"),
        make_row(quality_score: 0.8, cost_cents: 100, success: true, objective_score: nil, selection_mode: "exploitative")
      ]
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(rows)

      result = service.call

      expect(result.sufficient_data).to be true
      expect(result.objective_improvement).to be_nil
      expect(result.quality_improvement).to be > 0
    end

    it "handles zero cost gracefully in quality-per-dollar" do
      rows = [
        make_row(quality_score: 0.5, cost_cents: 0, success: true, objective_score: 0.45),
        make_row(quality_score: 0.6, cost_cents: 0, success: true, objective_score: 0.55),
        make_row(quality_score: 0.7, cost_cents: 100, success: true, objective_score: 0.65),
        make_row(quality_score: 0.8, cost_cents: 100, success: true, objective_score: 0.75)
      ]
      service = described_class.new(project: project)
      allow(service).to receive(:load_outcome_rows).and_return(rows)

      result = service.call

      expect(result.sufficient_data).to be true
      expect(result.early_quality_per_dollar).to be_nil
    end
  end
end
