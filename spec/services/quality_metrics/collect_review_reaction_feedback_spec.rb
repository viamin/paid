# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::CollectReviewReactionFeedback do
  describe ".call" do
    let(:agent_run) { create(:agent_run, :with_review) }
    let(:github_client) { instance_double(GithubClient) }
    let(:github_token) { agent_run.project.github_token }

    before do
      allow(github_token).to receive(:client).and_return(github_client)
    end

    it "creates human quality metric from batched reactions on review comments" do
      allow(github_client).to receive(:review_comment_reactions_batch)
        .with(agent_run.project.full_name, agent_run.source_pull_request_number, max_threads: 50)
        .and_return([
          { user_login: "alice", content: "+1", created_at: 1.hour.ago },
          { user_login: "bob", content: "rocket", created_at: 30.minutes.ago }
        ])

      metric = described_class.call(agent_run: agent_run)

      expect(metric).to be_persisted
      expect(metric.metric_type).to eq("human")
      expect(metric.scores["reaction_score"]).to eq(1.0)
      expect(metric.metadata["feedback_sources"]).to include("review_reaction")
    end

    it "calculates mixed reaction score from review comments" do
      allow(github_client).to receive(:review_comment_reactions_batch)
        .and_return([
          { user_login: "alice", content: "+1", created_at: 1.hour.ago },
          { user_login: "bob", content: "confused", created_at: 30.minutes.ago }
        ])

      metric = described_class.call(agent_run: agent_run)

      expect(metric.scores["reaction_score"]).to eq(0.5)
    end

    it "aggregates reactions across multiple review comments into tallied counts" do
      allow(github_client).to receive(:review_comment_reactions_batch)
        .and_return([
          { user_login: "alice", content: "+1", created_at: 1.hour.ago },
          { user_login: "bob", content: "+1", created_at: 45.minutes.ago },
          { user_login: "carol", content: "confused", created_at: 30.minutes.ago }
        ])

      metric = described_class.call(agent_run: agent_run)

      # 2 positive + 1 negative = 0.6667
      expect(metric.scores["reaction_score"]).to eq(0.6667)
      expect(metric.metadata["reaction_counts"]).to eq("+1" => 2, "confused" => 1)
    end

    it "returns nil when no reactions exist" do
      allow(github_client).to receive(:review_comment_reactions_batch).and_return([])

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end

    it "returns nil for non-review goals" do
      pr_run = create(:agent_run, :completed)

      result = described_class.call(agent_run: pr_run)

      expect(result).to be_nil
    end

    it "handles GitHub API errors gracefully" do
      allow(github_client).to receive(:review_comment_reactions_batch)
        .and_raise(GithubClient::ApiError.new("API error"))

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end

    it "uses a single batched GraphQL call instead of N+1 REST calls" do
      allow(github_client).to receive(:review_comment_reactions_batch)
        .with(agent_run.project.full_name, agent_run.source_pull_request_number, max_threads: 50)
        .and_return([])

      described_class.call(agent_run: agent_run)

      expect(github_client).to have_received(:review_comment_reactions_batch).once
    end
  end
end
