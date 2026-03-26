# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::CollectReviewFeedback do
  describe ".call" do
    let(:agent_run) { create(:agent_run, :completed) }

    context "with single review (webhook)" do
      it "records approved review as 1.0" do
        metric = described_class.call(
          agent_run: agent_run,
          review_state: "approved",
          reviewer: "octocat",
          review_body: "LGTM!"
        )

        expect(metric).to be_persisted
        expect(metric.metric_type).to eq("human")
        expect(metric.scores["review_score"]).to eq(1.0)
        expect(metric.metadata["reviews"]).to be_an(Array)
        expect(metric.metadata["feedback_sources"]).to include("pr_review")
      end

      it "records changes_requested review as 0.0" do
        metric = described_class.call(
          agent_run: agent_run,
          review_state: "changes_requested",
          reviewer: "octocat",
          review_body: "Please fix the tests"
        )

        expect(metric.scores["review_score"]).to eq(0.0)
      end

      it "records commented review as 0.5" do
        metric = described_class.call(
          agent_run: agent_run,
          review_state: "commented",
          reviewer: "octocat"
        )

        expect(metric.scores["review_score"]).to eq(0.5)
      end

      it "ignores dismissed reviews" do
        result = described_class.call(
          agent_run: agent_run,
          review_state: "dismissed",
          reviewer: "octocat"
        )

        expect(result).to be_nil
      end

      it "normalizes review state case" do
        metric = described_class.call(
          agent_run: agent_run,
          review_state: "APPROVED",
          reviewer: "octocat"
        )

        expect(metric.scores["review_score"]).to eq(1.0)
      end
    end

    context "with multiple reviews (polling)" do
      it "averages scores from multiple reviews" do
        metric = described_class.call(
          agent_run: agent_run,
          reviews: [
            { state: "APPROVED", user_login: "alice", body: "LGTM" },
            { state: "CHANGES_REQUESTED", user_login: "bob", body: "Needs work" }
          ]
        )

        expect(metric.scores["review_score"]).to eq(0.5)
      end

      it "skips dismissed reviews in average" do
        metric = described_class.call(
          agent_run: agent_run,
          reviews: [
            { state: "APPROVED", user_login: "alice", body: "" },
            { state: "DISMISSED", user_login: "bob", body: "" }
          ]
        )

        expect(metric.scores["review_score"]).to eq(1.0)
      end

      it "returns nil when all reviews are unscored" do
        result = described_class.call(
          agent_run: agent_run,
          reviews: [
            { state: "DISMISSED", user_login: "alice", body: "" }
          ]
        )

        expect(result).to be_nil
      end
    end

    it "merges review score into existing human metric" do
      existing = create(:quality_metric, :human, agent_run: agent_run)

      metric = described_class.call(
        agent_run: agent_run,
        review_state: "approved",
        reviewer: "octocat"
      )

      expect(metric.id).to eq(existing.id)
      expect(metric.scores).to include("pr_merged" => 1.0, "review_score" => 1.0)
    end
  end
end
