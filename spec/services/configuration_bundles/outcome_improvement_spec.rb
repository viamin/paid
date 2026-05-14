# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::OutcomeImprovement, :no_db do
  let(:project) { double(id: 42) }
  let(:service) { described_class.new(project: project) }

  def aggregate_row(overrides = {})
    {
      "early_objective_score" => 0.5,
      "recent_objective_score" => 0.75,
      "early_quality_score" => 0.55,
      "recent_quality_score" => 0.8,
      "early_cost_cents" => 180.0,
      "recent_cost_cents" => 120.0,
      "early_quality_per_dollar" => 0.3,
      "recent_quality_per_dollar" => 0.68,
      "exploitative_avg_objective" => 0.65,
      "exploratory_avg_objective" => 0.5,
      "exploitative_sample_count" => 5,
      "exploratory_sample_count" => 1
    }.merge(overrides)
  end

  def period_row(period_index:, outcome_count:, avg_objective_score:, avg_quality_score:, avg_cost_cents:, avg_quality_per_dollar:, success_rate:)
    {
      "period_index" => period_index,
      "outcome_count" => outcome_count,
      "avg_objective_score" => avg_objective_score,
      "avg_quality_score" => avg_quality_score,
      "avg_cost_cents" => avg_cost_cents,
      "avg_quality_per_dollar" => avg_quality_per_dollar,
      "success_rate" => success_rate
    }
  end

  def default_periods
    [
      period_row(period_index: 1, outcome_count: 3, avg_objective_score: 0.5, avg_quality_score: 0.55, avg_cost_cents: 180.0, avg_quality_per_dollar: 0.3, success_rate: 1.0),
      period_row(period_index: 2, outcome_count: 3, avg_objective_score: 0.75, avg_quality_score: 0.8, avg_cost_cents: 120.0, avg_quality_per_dollar: 0.68, success_rate: 1.0)
    ]
  end

  def stub_result(count:, aggregate: aggregate_row, periods: default_periods)
    allow(service).to receive_messages(
      outcome_count: count,
      load_aggregate_row: aggregate,
      load_period_rows: periods
    )
  end

  describe "with insufficient data" do
    it "returns insufficient data result when there are fewer than 4 outcomes" do
      allow(service).to receive(:outcome_count).and_return(3)

      result = service.call

      expect(result.sufficient_data).to be false
      expect(result.outcome_count).to eq(3)
      expect(result.objective_improvement).to be_nil
      expect(result.periods).to be_empty
    end

    it "returns insufficient data result when there are no outcomes" do
      allow(service).to receive(:outcome_count).and_return(0)

      result = service.call

      expect(result.sufficient_data).to be false
      expect(result.outcome_count).to eq(0)
    end
  end

  describe "with sufficient data" do
    before do
      stub_result(count: 6)
    end

    it "returns sufficient data result" do
      result = service.call

      expect(result.sufficient_data).to be true
      expect(result.outcome_count).to eq(6)
    end

    it "computes objective improvement between early and recent periods" do
      result = service.call

      expect(result.early_objective_score).to be_within(0.01).of(0.50)
      expect(result.recent_objective_score).to be_within(0.01).of(0.75)
      expect(result.objective_improvement).to be > 0
    end

    it "computes quality improvement between early and recent periods" do
      result = service.call

      expect(result.early_quality_score).to be_within(0.01).of(0.55)
      expect(result.recent_quality_score).to be_within(0.01).of(0.8)
      expect(result.quality_improvement).to be > 0
    end

    it "computes cost change between early and recent periods" do
      result = service.call

      expect(result.early_cost_cents).to be_within(1).of(180)
      expect(result.recent_cost_cents).to be_within(1).of(120)
      expect(result.cost_change_fraction).to be < 0
    end

    it "computes quality-per-dollar improvement" do
      result = service.call

      expect(result.recent_quality_per_dollar).to be > result.early_quality_per_dollar
      expect(result.quality_per_dollar_improvement).to be > 0
    end

    it "tracks exploitative vs exploratory outcomes" do
      result = service.call

      expect(result.exploitative_sample_count).to eq(5)
      expect(result.exploratory_sample_count).to eq(1)
    end

    it "computes optimizer learning ratio" do
      result = service.call

      expect(result.optimizer_learning_ratio).not_to be_nil
    end

    it "builds period snapshots" do
      result = service.call

      expect(result.periods.length).to eq(2)
      expect(result.periods.first).to be_a(described_class::PeriodSnapshot)
      expect(result.periods.first.outcome_count).to be > 0
      expect(result.periods.first.avg_objective_score).not_to be_nil
    end

    it "counts unscored outcomes while preserving scored aggregates" do
      stub_result(
        count: 6,
        aggregate: aggregate_row(
          "early_quality_score" => nil,
          "recent_quality_score" => 0.8
        ),
        periods: [
          period_row(period_index: 1, outcome_count: 3, avg_objective_score: 0.5, avg_quality_score: nil, avg_cost_cents: 180.0, avg_quality_per_dollar: nil, success_rate: 0.3333),
          period_row(period_index: 2, outcome_count: 3, avg_objective_score: 0.75, avg_quality_score: 0.8, avg_cost_cents: 120.0, avg_quality_per_dollar: 0.68, success_rate: 1.0)
        ]
      )

      result = service.call

      expect(result.outcome_count).to eq(6)
      expect(result.early_quality_score).to be_nil
      expect(result.periods.first.outcome_count).to eq(3)
      expect(result.periods.first.success_rate).to eq(0.3333)
    end
  end

  describe "quality-per-dollar fallback" do
    it "uses the aggregated quality-per-dollar averages from SQL" do
      stub_result(
        count: 4,
        aggregate: aggregate_row(
          "early_quality_per_dollar" => 0.55,
          "recent_quality_per_dollar" => 0.425
        )
      )

      result = service.call

      expect(result.early_quality_per_dollar).not_to be_nil
      expect(result.recent_quality_per_dollar).not_to be_nil
      expect(result.early_quality_per_dollar).to be_within(0.01).of(0.55)
      expect(result.recent_quality_per_dollar).to be_within(0.01).of(0.425)
    end
  end

  describe "optimizer learning ratio" do
    it "returns nil when there are no exploratory runs" do
      stub_result(
        count: 6,
        aggregate: aggregate_row(
          "exploitative_sample_count" => 6,
          "exploratory_sample_count" => 0,
          "exploratory_avg_objective" => nil
        )
      )

      result = service.call

      expect(result.optimizer_learning_ratio).to be_nil
      expect(result.exploratory_sample_count).to eq(0)
    end

    it "returns nil when there are no exploitative runs" do
      stub_result(
        count: 4,
        aggregate: aggregate_row(
          "exploitative_sample_count" => 0,
          "exploitative_avg_objective" => nil,
          "exploratory_sample_count" => 4
        )
      )

      result = service.call

      expect(result.optimizer_learning_ratio).to be_nil
      expect(result.exploitative_sample_count).to eq(0)
    end

    it "returns a positive ratio when exploitative outperforms exploratory" do
      stub_result(
        count: 4,
        aggregate: aggregate_row(
          "exploitative_avg_objective" => 0.825,
          "exploratory_avg_objective" => 0.475,
          "exploitative_sample_count" => 2,
          "exploratory_sample_count" => 2
        )
      )

      result = service.call

      expect(result.optimizer_learning_ratio).to be > 0
    end

    it "returns a negative ratio when exploratory outperforms exploitative" do
      stub_result(
        count: 4,
        aggregate: aggregate_row(
          "exploitative_avg_objective" => 0.475,
          "exploratory_avg_objective" => 0.825,
          "exploitative_sample_count" => 2,
          "exploratory_sample_count" => 2
        )
      )

      result = service.call

      expect(result.optimizer_learning_ratio).to be < 0
    end
  end

  describe "period snapshots" do
    it "divides outcomes into approximately equal periods" do
      stub_result(
        count: 8,
        periods: [
          period_row(period_index: 1, outcome_count: 4, avg_objective_score: 0.525, avg_quality_score: 0.575, avg_cost_cents: 170.0, avg_quality_per_dollar: 0.35, success_rate: 1.0),
          period_row(period_index: 2, outcome_count: 4, avg_objective_score: 0.725, avg_quality_score: 0.775, avg_cost_cents: 90.0, avg_quality_per_dollar: 0.8, success_rate: 1.0)
        ]
      )

      result = service.call

      expect(result.periods.length).to eq(2)
      expect(result.periods.map(&:outcome_count).sum).to eq(8)
    end

    it "does not create an extra runt period when rows are unevenly divisible" do
      stub_result(
        count: 5,
        periods: [
          period_row(period_index: 1, outcome_count: 2, avg_objective_score: 0.475, avg_quality_score: 0.525, avg_cost_cents: 190.0, avg_quality_per_dollar: 0.28, success_rate: 1.0),
          period_row(period_index: 2, outcome_count: 3, avg_objective_score: 0.6, avg_quality_score: 0.65, avg_cost_cents: 140.0, avg_quality_per_dollar: 0.52, success_rate: 1.0)
        ]
      )

      result = service.call

      expect(result.periods.length).to eq(2)
      expect(result.periods.map(&:outcome_count)).to eq([ 2, 3 ])
    end

    it "computes success rate per period" do
      stub_result(
        count: 4,
        periods: [
          period_row(period_index: 1, outcome_count: 2, avg_objective_score: 0.45, avg_quality_score: 0.5, avg_cost_cents: 100.0, avg_quality_per_dollar: 0.5, success_rate: 0.5),
          period_row(period_index: 2, outcome_count: 2, avg_objective_score: 0.85, avg_quality_score: 0.9, avg_cost_cents: 100.0, avg_quality_per_dollar: 0.9, success_rate: 1.0)
        ]
      )

      result = service.call

      expect(result.periods.first.success_rate).to eq(0.5)
      expect(result.periods.last.success_rate).to eq(1.0)
    end

    it "shows improving trend across periods" do
      stub_result(
        count: 4,
        periods: [
          period_row(period_index: 1, outcome_count: 2, avg_objective_score: 0.45, avg_quality_score: 0.5, avg_cost_cents: 200.0, avg_quality_per_dollar: 0.25, success_rate: 1.0),
          period_row(period_index: 2, outcome_count: 2, avg_objective_score: 0.85, avg_quality_score: 0.9, avg_cost_cents: 100.0, avg_quality_per_dollar: 0.9, success_rate: 1.0)
        ]
      )

      result = service.call

      expect(result.periods.last.avg_objective_score).to be > result.periods.first.avg_objective_score
      expect(result.periods.last.avg_cost_cents).to be < result.periods.first.avg_cost_cents
    end
  end

  describe "edge cases" do
    it "returns nil improvements when aggregated early values are missing" do
      stub_result(
        count: 4,
        aggregate: aggregate_row(
          "early_cost_cents" => nil,
          "early_quality_per_dollar" => nil
        )
      )

      result = service.call

      expect(result.cost_change_fraction).to be_nil
      expect(result.quality_per_dollar_improvement).to be_nil
    end

    it "handles zero early values gracefully in aggregate comparisons" do
      stub_result(
        count: 4,
        aggregate: aggregate_row(
          "early_quality_per_dollar" => 0.0,
          "recent_quality_per_dollar" => 10.0
        )
      )

      result = service.call

      expect(result.quality_per_dollar_improvement).to eq(0.0)
    end
  end

  describe "query shape" do
    let(:scope) { instance_double(ActiveRecord::Relation) }

    before do
      allow(service).to receive_messages(all_bundle_outcomes_scope: scope, outcome_count: 6)
      allow(scope).to receive(:select) do |sql|
        double(to_sql: sql.to_s)
      end
    end

    it "builds the annotated outcome query with windowing instead of plucking all rows" do
      sql = service.send(:annotated_outcomes_sql)

      expect(sql).to include("ROW_NUMBER() OVER")
      expect(sql).to include("period_index")
      expect(sql).to include("quality_per_dollar")
    end

    it "preserves the SQL fallback for historical objective scores" do
      sql = service.send(:annotated_outcomes_sql)

      expect(sql).to include("NULLIF(bundle_outcomes.metrics ->> 'objective_score', '')::double precision")
      expect(sql).to include("bundle_outcomes.duration_seconds")
      expect(sql).to include("ROUND(")
    end

    it "preserves the zero-cost floor for quality per dollar" do
      sql = service.send(:annotated_outcomes_sql)

      expect(sql).to include("NULLIF(bundle_outcomes.metrics ->> 'quality_per_dollar', '')::double precision")
      expect(sql).to include("GREATEST(bundle_outcomes.cost_cents / 100.0, 0.01)")
    end

    it "keeps unscored outcomes in the annotated dataset for counts and success rate" do
      sql = service.send(:annotated_outcomes_sql)

      expect(sql).not_to include("quality_score IS NOT NULL")
    end
  end
end
