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

    it "creates human quality metric from reactions on review" do
      allow(github_client).to receive_messages(
        pull_request_review_comments: [],
        issue_reactions: [
          { user_login: "alice", content: "+1", created_at: 1.hour.ago },
          { user_login: "bob", content: "rocket", created_at: 30.minutes.ago }
        ]
      )

      metric = described_class.call(agent_run: agent_run)

      expect(metric).to be_persisted
      expect(metric.metric_type).to eq("human")
      expect(metric.scores["reaction_score"]).to eq(1.0)
      expect(metric.metadata["feedback_sources"]).to include("review_reaction")
    end

    it "calculates mixed reaction score" do
      allow(github_client).to receive_messages(
        pull_request_review_comments: [],
        issue_reactions: [
          { user_login: "alice", content: "+1", created_at: 1.hour.ago },
          { user_login: "bob", content: "confused", created_at: 30.minutes.ago }
        ]
      )

      metric = described_class.call(agent_run: agent_run)

      expect(metric.scores["reaction_score"]).to eq(0.5)
    end

    it "includes reactions from review comments" do
      allow(github_client).to receive_messages(
        pull_request_review_comments: [
          { id: 101, user_login: "carol", body: "nit", created_at: 1.hour.ago }
        ],
        issue_reactions: [
          { user_login: "alice", content: "confused", created_at: 1.hour.ago }
        ]
      )
      allow(github_client).to receive(:pull_request_review_comment_reactions)
        .with(agent_run.project.full_name, 101)
        .and_return([
          { user_login: "dave", content: "+1", created_at: 30.minutes.ago }
        ])

      metric = described_class.call(agent_run: agent_run)

      # 1 positive (+1 on comment) + 1 negative (confused on PR) = 0.5
      expect(metric.scores["reaction_score"]).to eq(0.5)
    end

    it "returns nil when no reactions" do
      allow(github_client).to receive_messages(
        pull_request_review_comments: [],
        issue_reactions: []
      )

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end

    it "returns nil for non-review goals" do
      pr_run = create(:agent_run, :completed)

      result = described_class.call(agent_run: pr_run)

      expect(result).to be_nil
    end

    it "handles GitHub API errors gracefully" do
      allow(github_client).to receive(:pull_request_review_comments)
        .and_raise(GithubClient::ApiError.new("API error"))
      allow(github_client).to receive(:issue_reactions)
        .and_raise(GithubClient::ApiError.new("API error"))

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end
  end
end
