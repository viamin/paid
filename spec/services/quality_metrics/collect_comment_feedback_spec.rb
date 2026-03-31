# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::CollectCommentFeedback do
  describe ".call" do
    let(:agent_run) { create(:agent_run, :completed) }

    it "creates human quality metric with comment data" do
      metric = described_class.call(
        agent_run: agent_run,
        commenter: "alice",
        comment_id: 100
      )

      expect(metric).to be_persisted
      expect(metric.metric_type).to eq("human")
      expect(metric.metadata["webhook_comment_count"]).to eq(1)
      expect(metric.metadata["commenters"]).to eq([ "alice" ])
      expect(metric.metadata["feedback_sources"]).to include("comment")
      expect(metric.metadata["processed_comment_ids"]).to eq([ 100 ])
      expect(metric.scores).not_to have_key("webhook_comment_count_score")
    end

    it "increments comment count on repeated calls" do
      described_class.call(
        agent_run: agent_run,
        commenter: "alice"
      )

      metric = described_class.call(
        agent_run: agent_run,
        commenter: "bob"
      )

      expect(metric.metadata["webhook_comment_count"]).to eq(2)
      expect(metric.metadata["commenters"]).to contain_exactly("alice", "bob")
    end

    it "deduplicates commenter names" do
      described_class.call(
        agent_run: agent_run,
        commenter: "alice"
      )

      metric = described_class.call(
        agent_run: agent_run,
        commenter: "alice"
      )

      expect(metric.metadata["commenters"]).to eq([ "alice" ])
    end

    it "preserves existing scores from other feedback sources" do
      # Simulate pre-existing reaction score
      agent_run.quality_metrics.create!(
        metric_type: "human",
        scores: { "reaction_score" => 0.8 },
        metadata: { "feedback_sources" => [ "pr_reaction" ] },
        composite_score: 0.8
      )

      metric = described_class.call(
        agent_run: agent_run,
        commenter: "alice"
      )

      expect(metric.scores).to have_key("reaction_score")
      expect(metric.scores).not_to have_key("webhook_comment_count_score")
      expect(metric.metadata["feedback_sources"]).to include("pr_reaction", "comment")
    end

    it "deduplicates by comment_id on webhook retries" do
      described_class.call(
        agent_run: agent_run,
        commenter: "alice",
        comment_id: 42
      )

      metric = described_class.call(
        agent_run: agent_run,
        commenter: "alice",
        comment_id: 42
      )

      expect(metric.metadata["webhook_comment_count"]).to eq(1)
      expect(metric.metadata["processed_comment_ids"]).to eq([ 42 ])
    end

    it "counts distinct comments with different comment_ids" do
      described_class.call(
        agent_run: agent_run,
        commenter: "alice",
        comment_id: 42
      )

      metric = described_class.call(
        agent_run: agent_run,
        commenter: "bob",
        comment_id: 43
      )

      expect(metric.metadata["webhook_comment_count"]).to eq(2)
      expect(metric.metadata["processed_comment_ids"]).to contain_exactly(42, 43)
    end

    it "returns nil when commenter is blank" do
      result = described_class.call(
        agent_run: agent_run,
        commenter: nil
      )

      expect(result).to be_nil
      expect(agent_run.quality_metrics.human.count).to eq(0)
    end

    it "records the last comment timestamp" do
      freeze_time do
        metric = described_class.call(
          agent_run: agent_run,
          commenter: "alice"
        )

        expect(metric.metadata["last_comment_at"]).to eq(Time.current.iso8601)
      end
    end
  end
end
