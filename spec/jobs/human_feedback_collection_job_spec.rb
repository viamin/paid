# frozen_string_literal: true

require "rails_helper"

RSpec.describe HumanFeedbackCollectionJob do
  describe "#perform" do
    let(:github_client) { instance_double(GithubClient) }

    it "collects reactions and reviews for completed agent run with PR" do
      agent_run = create(:agent_run, :completed)
      allow(agent_run.project.github_token).to receive(:client).and_return(github_client)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      allow(github_client).to receive_messages(
        pull_request_reactions: [
          { user_login: "alice", content: "+1", created_at: 1.hour.ago }
        ],
        pull_request_reviews: [
          { state: "APPROVED", user_login: "bob", body: "LGTM" }
        ]
      )

      described_class.new.perform(agent_run.id)

      metric = agent_run.quality_metrics.human.first
      expect(metric).to be_present
      expect(metric.scores).to include("reaction_score", "review_score")
    end

    it "skips agent runs without pull request" do
      agent_run = create(:agent_run, :failed)

      expect {
        described_class.new.perform(agent_run.id)
      }.not_to change(QualityMetric, :count)
    end

    it "skips agent runs that are not finished" do
      agent_run = create(:agent_run, :running, pull_request_number: 1)

      expect {
        described_class.new.perform(agent_run.id)
      }.not_to change(QualityMetric, :count)
    end

    it "handles GitHub API errors for reviews gracefully" do
      agent_run = create(:agent_run, :completed)
      allow(agent_run.project.github_token).to receive(:client).and_return(github_client)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      allow(github_client).to receive(:pull_request_reactions).and_return([])
      allow(github_client).to receive(:pull_request_reviews)
        .and_raise(GithubClient::ApiError.new("rate limited"))

      expect {
        described_class.new.perform(agent_run.id)
      }.not_to raise_error
    end
  end
end
