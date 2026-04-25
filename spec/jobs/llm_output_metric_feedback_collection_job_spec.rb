# frozen_string_literal: true

require "rails_helper"

RSpec.describe LlmOutputMetricFeedbackCollectionJob do
  describe "#perform" do
    it "collects feedback for decision record metrics without composite scores" do
      project = create(:project)
      decision_record = create(:decision_record, project: project, status: "active", tags: %w[auth security])
      metric = create(:llm_output_metric, :decision_record,
        project: project,
        source_id: decision_record.id,
        composite_score: nil)

      described_class.new.perform

      metric.reload
      expect(metric.scores).to include("record_kept", "tag_count")
      expect(metric.composite_score).to be_present
    end

    it "skips metrics that already have a composite score" do
      project = create(:project)
      decision_record = create(:decision_record, project: project, status: "active")
      metric = create(:llm_output_metric, :decision_record,
        project: project,
        source_id: decision_record.id,
        scores: { "record_kept" => 1.0, "tag_count" => 1.0 },
        composite_score: 1.0)

      described_class.new.perform

      expect(metric.reload.composite_score).to eq(1.0)
    end

    it "skips metrics older than the lookback window" do
      project = create(:project)
      decision_record = create(:decision_record, project: project, status: "active")
      metric = create(:llm_output_metric, :decision_record,
        project: project,
        source_id: decision_record.id,
        composite_score: nil,
        created_at: 8.days.ago)

      described_class.new.perform

      expect(metric.reload.composite_score).to be_nil
    end

    it "handles missing decision records gracefully" do
      project = create(:project)
      create(:llm_output_metric, :decision_record,
        project: project,
        source_id: 999_999,
        composite_score: nil)

      expect { described_class.new.perform }.not_to raise_error
    end
  end
end
