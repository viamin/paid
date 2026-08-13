# frozen_string_literal: true

require "rails_helper"

RSpec.describe LlmOutputMetrics::CollectIssueTitleFeedback do
  let(:project) { create(:project) }
  let(:metric) do
    create(:llm_output_metric, :issue_title,
      project: project,
      source_id: 123)
  end

  before { metric }

  describe ".call" do
    it "returns nil when no metric exists" do
      result = described_class.call(
        project: project,
        issue_number: 999
      )

      expect(result).to be_nil
    end

    it "scores title_edited as 1.0 when not edited" do
      result = described_class.call(
        project: project,
        issue_number: 123,
        current_title: "Generated title",
        original_title: "Generated title"
      )

      expect(result.scores["title_edited"]).to eq(1.0)
    end

    it "scores title_edited as 0.0 when edited" do
      result = described_class.call(
        project: project,
        issue_number: 123,
        current_title: "User changed this",
        original_title: "Generated title"
      )

      expect(result.scores["title_edited"]).to eq(0.0)
    end

    it "scores positive reactions" do
      reactions = [
        { content: "+1" },
        { content: "rocket" }
      ]

      result = described_class.call(
        project: project,
        issue_number: 123,
        reactions: reactions
      )

      expect(result.scores["issue_reaction"]).to eq(1.0)
    end

    it "calculates composite score" do
      result = described_class.call(
        project: project,
        issue_number: 123,
        current_title: "Generated title",
        original_title: "Generated title",
        reactions: [ { content: "+1" } ]
      )

      expect(result.composite_score).to be_present
      # (1.0*0.60 + 1.0*0.40) / 1.0 = 1.0
      expect(result.composite_score).to eq(1.0)
    end
  end
end
