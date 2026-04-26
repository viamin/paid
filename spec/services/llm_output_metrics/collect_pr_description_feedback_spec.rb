# frozen_string_literal: true

require "rails_helper"

RSpec.describe LlmOutputMetrics::CollectPrDescriptionFeedback do
  let(:project) { create(:project) }
  let!(:metric) do
    create(:llm_output_metric, :pr_description,
      project: project,
      source_id: 42)
  end

  describe ".call" do
    it "returns nil when no metric exists" do
      result = described_class.call(
        project: project,
        pull_request_number: 999
      )

      expect(result).to be_nil
    end

    it "scores description_edited as 1.0 when not edited" do
      result = described_class.call(
        project: project,
        pull_request_number: 42,
        current_description: "Generated text",
        original_description: "Generated text"
      )

      expect(result.scores["description_edited"]).to eq(1.0)
    end

    it "scores description_edited as 0.0 when edited" do
      result = described_class.call(
        project: project,
        pull_request_number: 42,
        current_description: "User changed this",
        original_description: "Generated text"
      )

      expect(result.scores["description_edited"]).to eq(0.0)
    end

    it "scores description_length_ratio within ideal range" do
      result = described_class.call(
        project: project,
        pull_request_number: 42,
        current_description: "A" * 2000,
        diff_size: 1000
      )

      # ratio = 2.0 chars/line, within 0.5-10.0 range -> 1.0
      expect(result.scores["description_length_ratio"]).to eq(1.0)
    end

    it "penalizes very short descriptions relative to diff" do
      result = described_class.call(
        project: project,
        pull_request_number: 42,
        current_description: "A" * 10,
        diff_size: 10_000
      )

      # ratio = 0.001 chars/line, below MIN_LENGTH_RATIO (0.5) -> 0.001/0.5 = 0.002
      expect(result.scores["description_length_ratio"]).to eq(0.002)
    end

    it "scores positive reactions" do
      reactions = [
        { content: "+1" },
        { content: "heart" },
        { content: "-1" }
      ]

      result = described_class.call(
        project: project,
        pull_request_number: 42,
        reactions: reactions
      )

      # 2 positive / 3 total = 0.6667
      expect(result.scores["pr_reaction"]).to eq(0.6667)
    end

    it "calculates composite score from all signals" do
      reactions = [ { content: "+1" } ]

      result = described_class.call(
        project: project,
        pull_request_number: 42,
        current_description: "Generated text",
        original_description: "Generated text",
        diff_size: 1000,
        reactions: reactions
      )

      expect(result.composite_score).to be_present
      expect(result.composite_score).to be_between(0, 1)
    end

    it "returns existing metric when no signals are provided" do
      result = described_class.call(
        project: project,
        pull_request_number: 42
      )

      expect(result).to eq(metric)
    end
  end
end
