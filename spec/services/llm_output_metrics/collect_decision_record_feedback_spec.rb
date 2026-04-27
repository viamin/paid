# frozen_string_literal: true

require "rails_helper"

RSpec.describe LlmOutputMetrics::CollectDecisionRecordFeedback do
  let(:project) { create(:project) }
  let(:decision_record) do
    create(:decision_record, project: project, status: "active", tags: %w[auth api performance])
  end
  let(:metric) do
    create(:llm_output_metric, :decision_record,
      project: project,
      source_id: decision_record.id)
  end

  before { metric }

  describe ".call" do
    it "returns nil when no metric exists" do
      other_record = create(:decision_record, project: project)

      result = described_class.call(
        project: project,
        decision_record: other_record
      )

      expect(result).to be_nil
    end

    it "scores record_kept as 1.0 when status is active" do
      result = described_class.call(
        project: project,
        decision_record: decision_record
      )

      expect(result.scores["record_kept"]).to eq(1.0)
    end

    it "scores record_kept as 0.0 when status is reverted" do
      decision_record.update_columns(status: "reverted")

      result = described_class.call(
        project: project,
        decision_record: decision_record
      )

      expect(result.scores["record_kept"]).to eq(0.0)
    end

    it "scores tag_count as 1.0 with 3 or more tags" do
      result = described_class.call(
        project: project,
        decision_record: decision_record
      )

      expect(result.scores["tag_count"]).to eq(1.0)
    end

    it "scores tag_count proportionally with fewer tags" do
      decision_record.update_columns(tags: %w[auth])

      result = described_class.call(
        project: project,
        decision_record: decision_record
      )

      # 1/3 = 0.3333
      expect(result.scores["tag_count"]).to eq(0.3333)
    end

    it "scores tag_count as 0.0 with no tags" do
      decision_record.update_columns(tags: [])

      result = described_class.call(
        project: project,
        decision_record: decision_record
      )

      expect(result.scores["tag_count"]).to eq(0.0)
    end

    it "calculates composite score" do
      result = described_class.call(
        project: project,
        decision_record: decision_record
      )

      expect(result.composite_score).to be_present
      # (1.0*0.60 + 1.0*0.40) / 1.0 = 1.0
      expect(result.composite_score).to eq(1.0)
    end
  end
end
