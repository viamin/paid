# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::CollectIssueFeedback do
  describe ".call" do
    let(:agent_run) do
      create(:agent_run, :with_created_issue, status: "completed",
        started_at: 10.minutes.ago, completed_at: Time.current, duration_seconds: 600)
    end
    let(:github_client) { instance_double(GithubClient) }
    let(:github_token) { agent_run.project.github_token }

    before do
      allow(github_token).to receive(:client).and_return(github_client)
    end

    it "creates human quality metric from positive reactions on issue" do
      allow(github_client).to receive(:issue_reactions).and_return([
        { user_login: "alice", content: "+1", created_at: 1.hour.ago },
        { user_login: "bob", content: "heart", created_at: 30.minutes.ago }
      ])

      metric = described_class.call(agent_run: agent_run)

      expect(metric).to be_persisted
      expect(metric.metric_type).to eq("human")
      expect(metric.scores["reaction_score"]).to eq(1.0)
      expect(metric.metadata["reaction_counts"]).to include("+1" => 1, "heart" => 1)
      expect(metric.metadata["feedback_sources"]).to include("issue_reaction")
    end

    it "calculates mixed reaction score" do
      allow(github_client).to receive(:issue_reactions).and_return([
        { user_login: "alice", content: "+1", created_at: 1.hour.ago },
        { user_login: "bob", content: "-1", created_at: 30.minutes.ago },
        { user_login: "charlie", content: "+1", created_at: 15.minutes.ago }
      ])

      metric = described_class.call(agent_run: agent_run)

      expect(metric.scores["reaction_score"]).to eq(0.6667)
    end

    it "returns nil when no reactions" do
      allow(github_client).to receive(:issue_reactions).and_return([])

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end

    it "returns nil for non-issue-creation goals" do
      pr_run = create(:agent_run, :completed)

      result = described_class.call(agent_run: pr_run)

      expect(result).to be_nil
    end

    it "returns nil when no issue was created" do
      run = create(:agent_run, :create_issue_goal, status: "completed",
        started_at: 10.minutes.ago, completed_at: Time.current, duration_seconds: 600)

      result = described_class.call(agent_run: run)

      expect(result).to be_nil
    end

    it "handles GitHub API errors gracefully" do
      allow(github_client).to receive(:issue_reactions)
        .and_raise(GithubClient::ApiError.new("API error"))

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end
  end
end
