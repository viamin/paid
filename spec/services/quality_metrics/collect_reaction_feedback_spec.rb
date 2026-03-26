# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::CollectReactionFeedback do
  describe ".call" do
    let(:agent_run) { create(:agent_run, :completed) }
    let(:github_client) { instance_double(GithubClient) }
    let(:github_token) { agent_run.project.github_token }

    before do
      allow(github_token).to receive(:client).and_return(github_client)
    end

    it "creates human quality metric from positive reactions" do
      allow(github_client).to receive(:pull_request_reactions).and_return([
        { user_login: "alice", content: "+1", created_at: 1.hour.ago },
        { user_login: "bob", content: "heart", created_at: 30.minutes.ago }
      ])

      metric = described_class.call(agent_run: agent_run)

      expect(metric).to be_persisted
      expect(metric.metric_type).to eq("human")
      expect(metric.feedback_source).to eq("pr_reaction")
      expect(metric.scores["reaction_score"]).to eq(1.0)
      expect(metric.metadata["reaction_counts"]).to include("+1" => 1, "heart" => 1)
    end

    it "calculates mixed reaction score" do
      allow(github_client).to receive(:pull_request_reactions).and_return([
        { user_login: "alice", content: "+1", created_at: 1.hour.ago },
        { user_login: "bob", content: "-1", created_at: 30.minutes.ago },
        { user_login: "charlie", content: "+1", created_at: 15.minutes.ago }
      ])

      metric = described_class.call(agent_run: agent_run)

      expect(metric.scores["reaction_score"]).to eq(0.6667)
    end

    it "returns nil when no reactions" do
      allow(github_client).to receive(:pull_request_reactions).and_return([])

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end

    it "ignores neutral reactions (laugh, eyes)" do
      allow(github_client).to receive(:pull_request_reactions).and_return([
        { user_login: "alice", content: "laugh", created_at: 1.hour.ago },
        { user_login: "bob", content: "eyes", created_at: 30.minutes.ago }
      ])

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end

    it "returns nil when agent run has no pull request" do
      agent_run = create(:agent_run, :failed)

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end

    it "merges reaction score into existing human metric" do
      existing = create(:quality_metric, :human, agent_run: agent_run)
      allow(github_client).to receive(:pull_request_reactions).and_return([
        { user_login: "alice", content: "+1", created_at: 1.hour.ago }
      ])

      metric = described_class.call(agent_run: agent_run)

      expect(metric.id).to eq(existing.id)
      expect(metric.scores).to include("pr_merged" => 1.0, "reaction_score" => 1.0)
    end

    it "handles GitHub API errors gracefully" do
      allow(github_client).to receive(:pull_request_reactions)
        .and_raise(GithubClient::ApiError.new("API error"))

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end
  end
end
